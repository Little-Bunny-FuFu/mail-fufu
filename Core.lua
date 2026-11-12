-- Mail-fufu: Core.lua
-- Addon table, SavedVariables (init / defaults / version), event dispatcher, module
-- registry, chat output, slash command, shared popups.
--
-- Public contract (see README "Module contract"):
--   ns.modules[name] = Mod      register a module (order of registration = TOC order)
--   ns.RegisterModule(name, Mod)  same, returns Mod
--   ns.Dispatch(event, ...)     call Mod[event](...) on every module that defines it
--   ns.RegisterEvent(event)     ref-counted, pcall-safe extra event -> ns.Dispatch
--   ns.UnregisterEvent(event)
--   ns.GetOption(key) / ns.SetOption(key, value)
--   ns.Print(msg) / ns.PrintError(msg, noSound)
--   ns.RegisterSlash(sub, fn, quiet)
--   ns.db / ns.history          SavedVariables tables (valid from ADDON_LOADED on)

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

MailFufu = MailFufu or {}
MailFufu.ns = ns

ns.DB_VERSION = 1
ns.HISTORY_VERSION = 1

-- ---------------------------------------------------------------------------
-- Option definitions (§1.5). Ordered: Options.lua builds the panel from this list.
-- section = panel header key; kind = "bool" | "number".
-- ---------------------------------------------------------------------------
ns.OPTION_DEFS = {
	{ key = "autoAddSelf",          kind = "bool",   default = false, section = "SEND" },
	{ key = "maxRecent",            kind = "number", default = 15,    section = "SEND", min = 8, max = 40, step = 1 },
	{ key = "includeFriends",       kind = "bool",   default = false, section = "SEND" },
	{ key = "includeGuild",         kind = "bool",   default = false, section = "SEND" },
	{ key = "inclusiveSearch",      kind = "bool",   default = false, section = "SEND" },
	{ key = "blizzardAutocomplete", kind = "bool",   default = false, section = "SEND" },
	{ key = "hideDropdown",         kind = "bool",   default = false, section = "SEND" },
	{ key = "showOpenAll",          kind = "bool",   default = true,  section = "INBOX" },
	{ key = "rightClickTake",       kind = "bool",   default = false, section = "INBOX" },
	{ key = "rightClickDelete",     kind = "bool",   default = false, section = "INBOX" },
	{ key = "promptDeleteRead",     kind = "bool",   default = true,  section = "INBOX" },
	{ key = "deletePendingAuction", kind = "bool",   default = false, section = "INBOX" },
	{ key = "tooltipText",          kind = "bool",   default = false, section = "INBOX" },
	{ key = "printMoney",           kind = "bool",   default = true,  section = "CHAT" },
	{ key = "printTotal",           kind = "bool",   default = true,  section = "CHAT" },
	{ key = "historyLength",        kind = "number", default = 100,   section = "HISTORY", min = 0, max = 500, step = 10 },
	{ key = "historyMovable",       kind = "bool",   default = true,  section = "HISTORY" },
}

-- key -> default, key -> def
ns.defaults = {}
local defByKey = {}
for _, def in ipairs(ns.OPTION_DEFS) do
	ns.defaults[def.key] = def.default
	defByKey[def.key] = def
end

-- ---------------------------------------------------------------------------
-- Chat output
-- ---------------------------------------------------------------------------
local PREFIX_OK  = "|cff33ff99" .. L.CHAT_PREFIX .. "|r "
local PREFIX_ERR = "|cffff3333" .. L.CHAT_PREFIX .. "|r "

function ns.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX_OK .. tostring(msg))
end

-- Red line plus the quest-abandon sound. Pass noSound = true to stay silent.
function ns.PrintError(msg, noSound)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX_ERR .. "|cffff3333" .. tostring(msg) .. "|r")
	if not noSound then
		PlaySound(SOUNDKIT.IG_QUEST_LOG_ABANDON_QUEST)
	end
end

-- ---------------------------------------------------------------------------
-- Module registry. Assigning ns.modules[name] = Mod records registration order, so
-- OnLogin and dispatch run in TOC order without the modules knowing about each other.
-- ---------------------------------------------------------------------------
local moduleOrder = {}

local function SafeCall(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		-- Report through the normal error handler (BugSack) but keep other modules running.
		geterrorhandler()(err)
	end
end

ns.modules = setmetatable({}, {
	__newindex = function(t, name, mod)
		rawset(t, name, mod)
		tinsert(moduleOrder, mod)
		-- A module registered after login still gets its OnLogin.
		if ns.loggedIn and type(mod.OnLogin) == "function" then
			SafeCall(mod.OnLogin)
		end
	end,
})

function ns.RegisterModule(name, mod)
	if ns.modules[name] == nil then
		ns.modules[name] = mod
	end
	return ns.modules[name]
end

-- Call Mod[event](...) on every registered module that defines it (no self argument).
-- Used for game events and for the addon's own messages (OPTION_CHANGED, MAIL_SENT, ...).
function ns.Dispatch(event, ...)
	for i = 1, #moduleOrder do
		local fn = moduleOrder[i][event]
		if type(fn) == "function" then
			SafeCall(fn, ...)
		end
	end
end

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------
local function ValidOption(key, value)
	local def = defByKey[key]
	if not def then return false end
	if def.kind == "bool" then
		return type(value) == "boolean"
	end
	return type(value) == "number" and value >= def.min and value <= def.max
end

-- Fill missing or invalid option values from the defaults; never touches other keys.
local function MergeDefaults(options)
	for key, default in pairs(ns.defaults) do
		if not ValidOption(key, options[key]) then
			options[key] = default
		end
	end
end

local function InitSavedVariables()
	if type(MailFufuDB) ~= "table" then
		MailFufuDB = {}
	end
	local db = MailFufuDB
	if type(db.version) ~= "number" then
		db.version = ns.DB_VERSION
	end
	-- Future migrations: if db.version < ns.DB_VERSION then ... end
	if type(db.options) ~= "table" then db.options = {} end
	if type(db.realms) ~= "table" then db.realms = {} end
	if type(db.ui) ~= "table" then db.ui = {} end
	MergeDefaults(db.options)
	db.version = ns.DB_VERSION

	if type(MailFufuHistory) ~= "table" then
		MailFufuHistory = {}
	end
	local history = MailFufuHistory
	if type(history.version) ~= "number" then
		history.version = ns.HISTORY_VERSION
	end
	if type(history.entries) ~= "table" then history.entries = {} end
	history.version = ns.HISTORY_VERSION

	ns.db = db
	ns.history = history
	MailFufu.db = db
	MailFufu.history = history
end

-- ---------------------------------------------------------------------------
-- Options access
-- ---------------------------------------------------------------------------

-- Current value, or the default before SavedVariables are loaded.
function ns.GetOption(key)
	local db = ns.db
	if db and db.options[key] ~= nil then
		return db.options[key]
	end
	return ns.defaults[key]
end

-- Store a value and dispatch OPTION_CHANGED(key, value) when it changed.
-- Numbers are rounded and clamped to the option's range.
function ns.SetOption(key, value)
	local def = defByKey[key]
	if not def or not ns.db then return end
	if def.kind == "number" then
		value = tonumber(value)
		if not value then return end
		value = math.floor(value + 0.5)
		if value < def.min then value = def.min end
		if value > def.max then value = def.max end
	else
		value = value and true or false
	end
	if ns.db.options[key] == value then return end
	ns.db.options[key] = value
	ns.Dispatch("OPTION_CHANGED", key, value)
end

-- ---------------------------------------------------------------------------
-- Popups shared by several modules. Modules may add their own MAILFUFU_* dialogs.
-- ---------------------------------------------------------------------------
StaticPopupDialogs["MAILFUFU_NOTICE"] = {
	text = "%s",
	button1 = OKAY,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

-- data = callback run on accept.
StaticPopupDialogs["MAILFUFU_CONFIRM"] = {
	text = "%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, data)
		if type(data) == "function" then data() end
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

function ns.ShowNotice(text)
	StaticPopup_Show("MAILFUFU_NOTICE", text)
end

-- Yes/No prompt; onAccept runs only when the player clicks Yes.
function ns.Confirm(text, onAccept)
	StaticPopup_Show("MAILFUFU_CONFIRM", text, nil, onAccept)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

local eventRefs = {}

-- Extra (optional) event routed to ns.Dispatch. pcall-wrapped because Forever throws on
-- unknown event names. Ref-counted so two modules can share an event. Returns true when
-- the event is registered.
function ns.RegisterEvent(event)
	local refs = eventRefs[event] or 0
	if refs == 0 then
		if not Compat.SafeRegisterEvent(eventFrame, event) then
			return false
		end
	end
	eventRefs[event] = refs + 1
	return true
end

function ns.UnregisterEvent(event)
	local refs = eventRefs[event]
	if not refs or refs <= 0 then return end
	refs = refs - 1
	if refs == 0 then
		eventRefs[event] = nil
		Compat.SafeUnregisterEvent(eventFrame, event)
	else
		eventRefs[event] = refs
	end
end

-- Core lifecycle events plus the mail events marked VERIFIED-both in §2.4 (plain
-- RegisterEvent: these exist on retail 12.1.x and Forever 1.60).
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("MAIL_CLOSED")
eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
eventFrame:RegisterEvent("MAIL_SEND_SUCCESS")
eventFrame:RegisterEvent("MAIL_FAILED")
eventFrame:RegisterEvent("CLOSE_INBOX_ITEM")

local function OnLogin()
	ns.loggedIn = true
	for i = 1, #moduleOrder do
		local fn = moduleOrder[i].OnLogin
		if type(fn) == "function" then
			SafeCall(fn)
		end
	end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON then
			InitSavedVariables()
			self:UnregisterEvent("ADDON_LOADED")
		end
	elseif event == "PLAYER_LOGIN" then
		self:UnregisterEvent("PLAYER_LOGIN")
		OnLogin()
	else
		ns.Dispatch(event, ...)
		if event == "MAIL_SHOW" then
			ns.Dispatch("OnMailShow")
		elseif event == "MAIL_CLOSED" then
			ns.Dispatch("OnMailClosed")
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Slash command: /mailfufu [sub ...]
-- ---------------------------------------------------------------------------
local slashHandlers = {}
local slashOrder = {}

-- Register a subcommand. fn(rest) receives the remaining text (trimmed).
-- quiet = true keeps the subcommand out of the usage line.
function ns.RegisterSlash(sub, fn, quiet)
	sub = strlower(sub)
	if not slashHandlers[sub] and not quiet then
		tinsert(slashOrder, sub)
	end
	slashHandlers[sub] = fn
end

local function BoolText(v)
	return v and "true" or "false"
end

local function Debug()
	local version, build, buildDate, toc = GetBuildInfo()
	ns.Print(L.DEBUG_HEADER)
	ns.Print(format(L.DEBUG_BUILD, tostring(version), tostring(build), tostring(buildDate), tostring(toc)))
	ns.Print(format(L.DEBUG_PROJECT, tostring(WOW_PROJECT_ID)))
	ns.Print(format(L.DEBUG_MIXIN_MAIL, BoolText(Compat.HasMixinMail())))
	ns.Print(format(L.DEBUG_TYPE, "InboxFrame_Update", type(_G.InboxFrame_Update)))
	ns.Print(format(L.DEBUG_TYPE, "InboxFrame.Update", InboxFrame and type(InboxFrame.Update) or "nil (no InboxFrame)"))
	ns.Print(format(L.DEBUG_TYPE, "GetGuildRosterInfo", type(_G.GetGuildRosterInfo)))
	ns.Print(format(L.DEBUG_TYPE, "GetItemInfo", type(_G.GetItemInfo)))
	ns.Print(format(L.DEBUG_REALM, Compat.RealmKey()))
	ns.Print(format(L.DEBUG_FACTION, Compat.FactionKey()))
	ns.Print(format(L.DEBUG_FOREVER, BoolText(Compat.IsForever())))
end

ns.RegisterSlash("debug", Debug)

SLASH_MAILFUFU1 = "/mailfufu"
SlashCmdList["MAILFUFU"] = function(msg)
	msg = strtrim(msg or "")
	local sub, rest = msg:match("^(%S+)%s*(.-)$")
	if not sub or sub == "" then
		if ns.Options and ns.Options.Open then
			ns.Options.Open()
		end
		return
	end
	local fn = slashHandlers[strlower(sub)]
	if fn then
		fn(rest)
	else
		ns.PrintError(format(L.SLASH_UNKNOWN, sub), true)
		ns.Print(format(L.SLASH_USAGE, table.concat(slashOrder, " | ")))
	end
end
