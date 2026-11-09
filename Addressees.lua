-- Mail-fufu: Addressees.lua
-- Addressee data and sources for the Send Mail tab (design plan §1.1 S1-S7, §3.5):
--   * recently-mailed list per realm + faction (LRU, S2) and last addressee per character (S1)
--   * name-case normalisation (S3)
--   * Add Name / remove prompts (S5, S4 right-click)
--   * friends and guild sources (S6)
--   * autocomplete source plugged into Blizzard's own To-field autocomplete (S7)
--   * the addressee dropdown menu (S4), built with the Menu API
-- SendMail.lua owns the To field itself (prefill, dropdown button, send capture).
--
-- Blizzard names used here, checked against wow-ui-source (live 12.1.5 + origin/forever):
--   AutoCompleteEditBox_SetAutoCompleteSource(editBox, source, ...)
--       Blizzard_AutoComplete/AutoComplete.lua; stores editBox.autoCompleteSource/Params.
--       Callers: AutoComplete_Update (maxResults = AUTOCOMPLETE_MAX_BUTTONS + 1) and
--       AutoCompleteEditBox_AddHighlightedText (maxResults = 1, uses result [1] for the
--       inline tail highlight). Results are { name = string, priority = Enum.AutoCompletePriority.* };
--       AutoComplete_UpdateResults indexes AUTOCOMPLETE_COLOR_KEYS[priority], so the priority
--       must be a real enum member.
--   SendMailNameEditBox OnLoad (Blizzard_MailFrame/MailFrame.xml) installs
--       C_AutoComplete.GetAutoCompleteResults with AUTOCOMPLETE_LIST.MAIL.include/.exclude.
--   Menu API (Blizzard_Menu): MenuUtil.CreateContextMenu(owner, generator) returns the menu
--       proxy; description:CreateTemplate/CreateButton/CreateTitle/CreateDivider/SetScrollMode;
--       element description :SetData/:SetResponder/:Pick/:AddInitializer; MenuVariants.
--       CreateFontString/CreateHighlight (MenuVariants.lua); MenuInputContext.MouseButton,
--       MenuResponse.CloseAll (MenuConstants.lua); menu proxy :Close()/:GetOwnerRegion().
--   C_FriendList.GetNumFriends/GetFriendInfoByIndex(i).name/ShowFriends (FriendListDocumentation)
--   BNGetNumFriends() (FriendsFrame.lua), C_BattleNet.GetFriendAccountInfo(i).gameAccountInfo.
--       {isOnline, clientProgram, wowProjectID, characterName, realmName} (BattleNetDocumentation)
--   BNET_CLIENT_WOW (Blizzard_SharedXML/AccountUtil.lua)
--   C_Club.GetGuildClubId/GetClubMembers/GetMemberInfo(...).{name, isSelf} (ClubDocumentation)
--   C_GuildInfo.GuildRoster (GuildInfoDocumentation), IsInGuild/GetNumGuildMembers (MailFrame.lua)
--   StaticPopup dialog:GetEditBox() (Blizzard_StaticPopup/StaticPopup.lua, both branches)

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local strbyte, strsub, strfind, strgsub = string.byte, string.sub, string.find, string.gsub
local sort = table.sort

local Addressees = {}
ns.Addressees = Addressees
ns.RegisterModule("Addressees", Addressees)

local MENU_BUTTON_TEMPLATE = "MailFufuMenuButtonTemplate" -- Addressees.xml
local MENU_MAX_ROWS = 15
local MENU_ROW_HEIGHT = 20                                 -- MenuVariants.CreateFontString height
local ADD_NAME_MAX_LETTERS = 77                            -- SendMailNameEditBox letters="77"

local COLOR_ADD   = "|cff20ff20"
local COLOR_CLEAR = "|cff40e0ff"
local COLOR_END   = "|r"

local active = false        -- OnLogin ran (not a limited account, mail UI present)
local origSource, origParams

-- ---------------------------------------------------------------------------
-- Name normalisation (S3)
-- ---------------------------------------------------------------------------
local NO_CASE_LOCALES = { koKR = true, zhCN = true, zhTW = true }

local function CaseFolding()
	return not NO_CASE_LOCALES[GetLocale()]
end

-- Byte length of the UTF-8 character starting at position i (lead-byte arithmetic; the
-- client has no utf8 library).
local function Utf8CharLen(s, i)
	local b = strbyte(s, i)
	if not b then return 0 end
	if b >= 0xF0 then return 4 end
	if b >= 0xE0 then return 3 end
	if b >= 0xC0 then return 2 end
	return 1
end

-- First character upper-case, rest of the character name lower-case. Only the part before
-- the first "-" is touched, so a "-RealmName" suffix keeps its spelling. Skipped for
-- locales without letter case. Returns "" for empty / non-string input.
function Addressees.NameCase(name)
	if type(name) ~= "string" then return "" end
	name = strtrim(name)
	if name == "" or not CaseFolding() then return name end
	local dash = strfind(name, "-", 1, true)
	local base, rest = name, ""
	if dash then
		base, rest = strsub(name, 1, dash - 1), strsub(name, dash)
	end
	if base == "" then return name end
	local n = Utf8CharLen(base, 1)
	-- UNVERIFIED: whether the client's strupper/strlower fold non-ASCII (multi-byte) letters;
	-- if they do not, accented names simply keep their typed case for those letters.
	return strupper(strsub(base, 1, n)) .. strlower(strsub(base, n + 1)) .. rest
end
local NameCase = Addressees.NameCase

-- Case-insensitive comparison key (exact for locales without letter case).
local function Key(name)
	if CaseFolding() then
		return strlower(name)
	end
	return name
end

local function PlayerName()
	return (UnitName("player"))
end

local function IsSelf(name)
	local me = PlayerName()
	if not me or not name then return false end
	-- Ambiguate drops our own realm suffix so "Me-MyRealm" also counts as self.
	return Key(Ambiguate(name, "none")) == Key(me)
end

local function SortByKey(list)
	sort(list, function(a, b) return Key(a) < Key(b) end)
end

-- ---------------------------------------------------------------------------
-- Store: MailFufuDB.realms[realmKey][faction] = { recent = {...}, lastTo = {...} } (§3.8)
-- ---------------------------------------------------------------------------
function Addressees.GetStore()
	local db = ns.db
	if not db then return nil end
	local realmKey, faction = Compat.RealmKey(), Compat.FactionKey()
	if type(db.realms) ~= "table" then db.realms = {} end
	if type(db.realms[realmKey]) ~= "table" then db.realms[realmKey] = {} end
	local realm = db.realms[realmKey]
	if type(realm[faction]) ~= "table" then realm[faction] = {} end
	local store = realm[faction]
	if type(store.recent) ~= "table" then store.recent = {} end
	if type(store.lastTo) ~= "table" then store.lastTo = {} end
	return store
end
local GetStore = Addressees.GetStore

local function MaxRecent()
	return ns.GetOption("maxRecent") or ns.defaults.maxRecent
end

local function IndexOf(list, name)
	local k = Key(name)
	for i = 1, #list do
		if Key(list[i]) == k then return i end
	end
	return nil
end

-- Drop the oldest entries (front of the list) until it fits.
local function Truncate(list, max)
	while #list > max do
		tremove(list, 1)
	end
end

-- LRU update (S2): move to the newest position, or append and drop the oldest when full.
function Addressees.Remember(name)
	name = NameCase(name)
	if name == "" then return end
	local store = GetStore()
	if not store then return end
	local list = store.recent
	local i = IndexOf(list, name)
	if i then tremove(list, i) end
	tinsert(list, name)
	Truncate(list, MaxRecent())
end

-- Add Name (S5). Returns "added" | "exists" | "invalid", plus the normalised name.
-- The last addressee (S1) is never touched.
function Addressees.AddManual(name)
	name = NameCase(name)
	if name == "" then return "invalid", name end
	local store = GetStore()
	if not store then return "invalid", name end
	if IndexOf(store.recent, name) then
		return "exists", name
	end
	Addressees.Remember(name)
	return "added", name
end

-- Returns true when the name was in the list.
function Addressees.Remove(name)
	local store = GetStore()
	if not store or type(name) ~= "string" then return false end
	local i = IndexOf(store.recent, name)
	if not i then return false end
	tremove(store.recent, i)
	return true
end

-- Empty the recent list of the current realm + faction. The last addressee per character
-- (S1) is kept. Called by the Clear List button in Options.lua (which confirms first).
function Addressees.Clear()
	local store = GetStore()
	if store then wipe(store.recent) end
end

function Addressees.SetLastTo(name)
	name = NameCase(name)
	local store, me = GetStore(), PlayerName()
	if name == "" or not store or not me then return end
	store.lastTo[me] = name
end

function Addressees.GetLastTo()
	local store, me = GetStore(), PlayerName()
	if not store or not me then return nil end
	local name = store.lastTo[me]
	if type(name) == "string" and name ~= "" then return name end
	return nil
end

-- Alphabetical copy of the recent list without the current character.
function Addressees.GetSorted()
	local out = {}
	local store = GetStore()
	if not store then return out end
	for _, name in ipairs(store.recent) do
		if not IsSelf(name) then tinsert(out, name) end
	end
	SortByKey(out)
	return out
end

-- Newest-first copy of the recent list without the current character (autocomplete order).
local function GetNewestFirst()
	local out = {}
	local store = GetStore()
	if not store then return out end
	for i = #store.recent, 1, -1 do
		local name = store.recent[i]
		if not IsSelf(name) then tinsert(out, name) end
	end
	return out
end

-- Drop non-string, empty and duplicate entries (the newest occurrence wins) and truncate to
-- maxRecent. Also drops non-string last-addressee values.
function Addressees.Sanitize()
	local store = GetStore()
	if not store then return end
	local list = store.recent
	local seen, keptNewestFirst = {}, {}
	for i = #list, 1, -1 do
		local name = list[i]
		if type(name) == "string" then
			name = strtrim(name)
			if name ~= "" and not seen[Key(name)] then
				seen[Key(name)] = true
				tinsert(keptNewestFirst, name)
			end
		end
	end
	wipe(list)
	for i = #keptNewestFirst, 1, -1 do
		tinsert(list, keptNewestFirst[i])
	end
	Truncate(list, MaxRecent())

	for char, name in pairs(store.lastTo) do
		if type(char) ~= "string" or type(name) ~= "string" or name == "" then
			store.lastTo[char] = nil
		end
	end
end

-- "Add logged-in characters" (S2): add this character if absent and the list is not full.
function Addressees.AutoAddSelf()
	if not ns.GetOption("autoAddSelf") then return end
	local store, me = GetStore(), PlayerName()
	if not store or not me then return end
	local name = NameCase(me)
	if IndexOf(store.recent, name) or #store.recent >= MaxRecent() then return end
	tinsert(store.recent, name)
end

-- ---------------------------------------------------------------------------
-- Friends and guild sources (S6). Cached sorted arrays rebuilt lazily (dirty flags).
-- ---------------------------------------------------------------------------
local friends, guild = {}, {}
local friendsDirty, guildDirty = true, true
local friendEventsOn, guildEventsOn = false, false
local eventFailReported = {}

local FRIEND_EVENTS = { "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED" }
local GUILD_EVENTS = { "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE" }

local function SetEvents(list, on)
	for _, event in ipairs(list) do
		if on then
			-- ns.RegisterEvent is pcall-wrapped (Forever throws on unknown event names).
			if not ns.RegisterEvent(event) and not eventFailReported[event] then
				eventFailReported[event] = true
				ns.PrintError(format(L.EVENT_REGISTER_FAILED, event), true)
			end
		else
			ns.UnregisterEvent(event)
		end
	end
end

local function UpdateFriendEvents()
	local want = active and ns.GetOption("includeFriends") and true or false
	if want ~= friendEventsOn then
		SetEvents(FRIEND_EVENTS, want)
		friendEventsOn = want
	end
	friendsDirty = true
end

local function UpdateGuildEvents()
	local want = active and ns.GetOption("includeGuild") and true or false
	if want ~= guildEventsOn then
		SetEvents(GUILD_EVENTS, want)
		guildEventsOn = want
	end
	guildDirty = true
end

local function RequestFriends()
	if C_FriendList and C_FriendList.ShowFriends then
		C_FriendList.ShowFriends()
	end
end

local function RequestGuild()
	if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	end
end

-- Mail can only be addressed to characters of this game, so Battle.net friends count only
-- when online on a WoW character of the same project. A different realm becomes
-- "Name-Realm" with the spaces removed (the form the To field and Ambiguate use).
local function BuildFriends()
	wipe(friends)
	local seen = {}
	local myRealm = GetRealmName()
	local function Add(name)
		if type(name) ~= "string" or name == "" or IsSelf(name) then return end
		local k = Key(name)
		if seen[k] then return end
		seen[k] = true
		tinsert(friends, name)
	end

	if C_FriendList and C_FriendList.GetNumFriends then
		for i = 1, C_FriendList.GetNumFriends() or 0 do
			local info = C_FriendList.GetFriendInfoByIndex(i)
			Add(info and info.name)
		end
	end

	if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
		local total = BNGetNumFriends() or 0
		for i = 1, total do
			local account = C_BattleNet.GetFriendAccountInfo(i)
			local game = account and account.gameAccountInfo
			if game and game.isOnline and game.clientProgram == BNET_CLIENT_WOW
				and (WOW_PROJECT_ID == nil or game.wowProjectID == WOW_PROJECT_ID)
				and type(game.characterName) == "string" and game.characterName ~= ""
				and type(game.realmName) == "string" and game.realmName ~= "" then
				local name = game.characterName
				-- UNVERIFIED: that the mail server accepts "Name-RealmWithoutSpaces" for a
				-- display realm name containing spaces (no Blizzard Lua builds this form).
				if game.realmName ~= myRealm then
					name = name .. "-" .. strgsub(game.realmName, "%s", "")
				end
				Add(name)
			end
		end
	end

	SortByKey(friends)
end

local function BuildGuild()
	wipe(guild)
	if not IsInGuild() then return end
	local seen = {}
	local function Add(name)
		if type(name) ~= "string" or name == "" then return end
		name = Ambiguate(name, "none")
		if IsSelf(name) then return end
		local k = Key(name)
		if seen[k] then return end
		seen[k] = true
		tinsert(guild, name)
	end

	-- UNVERIFIED: GetGuildRosterInfo has no Blizzard Lua caller on either branch (plan §2.2);
	-- long-standing C global that historically only covers the SHOWN roster (online-only
	-- unless "show offline" is on). The pass is therefore result-driven: when it returned
	-- no names, or fewer than GetNumGuildMembers() reports in total, the documented C_Club
	-- pass runs as well (duplicates are dropped by Add).
	local total = GetNumGuildMembers() or 0
	local got = 0
	local rosterInfo = _G.GetGuildRosterInfo
	if type(rosterInfo) == "function" then
		for i = 1, total do
			local name = rosterInfo(i)
			if type(name) == "string" and name ~= "" then
				got = got + 1
				Add(name)
			end
		end
	end
	if (got == 0 or got < total) and C_Club and C_Club.GetGuildClubId then
		local clubId = C_Club.GetGuildClubId()
		if clubId then
			for _, memberId in ipairs(C_Club.GetClubMembers(clubId) or {}) do
				local info = C_Club.GetMemberInfo(clubId, memberId)
				if info and not info.isSelf then
					Add(info.name)
				end
			end
		end
	end

	SortByKey(guild)
end

-- pcall: 12.x marks some roster/club values secret during chat-messaging lockdown; a
-- failed rebuild must not break the dropdown or Blizzard's autocomplete.
local function SafeBuild(fn, list)
	local ok, err = pcall(fn)
	if not ok then
		wipe(list)
		geterrorhandler()(err)
	end
end

function Addressees.GetFriends()
	if not ns.GetOption("includeFriends") then return {} end
	if friendsDirty then
		friendsDirty = false
		SafeBuild(BuildFriends, friends)
	end
	return friends
end

function Addressees.GetGuild()
	if not ns.GetOption("includeGuild") then return {} end
	if guildDirty then
		guildDirty = false
		SafeBuild(BuildGuild, guild)
	end
	return guild
end

function Addressees.RefreshFriends()
	friendsDirty = true
	return Addressees.GetFriends()
end

function Addressees.RefreshGuild()
	guildDirty = true
	return Addressees.GetGuild()
end

-- Dirty-flag event handlers (registered only while the matching option is on).
function Addressees.FRIENDLIST_UPDATE() friendsDirty = true end
function Addressees.BN_FRIEND_INFO_CHANGED() friendsDirty = true end
function Addressees.GUILD_ROSTER_UPDATE() guildDirty = true end
function Addressees.PLAYER_GUILD_UPDATE() guildDirty = true end

-- ---------------------------------------------------------------------------
-- Autocomplete source (S7)
-- ---------------------------------------------------------------------------
local function Priority(member)
	local enum = Enum and Enum.AutoCompletePriority
	if not enum then return 0 end
	return enum[member] or enum.Other or 0
end

-- Same signature as C_AutoComplete.GetAutoCompleteResults as Blizzard calls it:
-- (text, maxResults, cursorPosition, allowFullMatch, include, exclude).
function Addressees.Source(text, maxResults, cursorPosition, allowFullMatch, ...)
	local blizz
	if origSource then
		local ok, res = pcall(origSource, text, maxResults, cursorPosition, allowFullMatch, ...)
		if ok and type(res) == "table" then blizz = res end
	end
	blizz = blizz or {}
	if type(text) ~= "string" or text == "" then
		return blizz
	end
	maxResults = maxResults or 10

	local prefix = Key(text)
	local plen = #prefix
	local function Matches(name)
		local k = Key(name)
		if strsub(k, 1, plen) ~= prefix then return false end
		if not allowFullMatch and k == prefix then return false end
		return true
	end

	-- Blizzard's own results (entry ~= nil) are already filtered by the client; they are
	-- only de-duplicated against ours, never re-matched.
	local results, seen = {}, {}
	local function Add(name, priority, entry)
		if type(name) ~= "string" then return end
		if not entry and not Matches(name) then return end
		local k = Key(Ambiguate(name, "none"))
		if seen[k] then return end
		seen[k] = true
		tinsert(results, entry or { name = name, priority = priority })
	end

	local recentPriority, friendPriority, guildPriority =
		Priority("Interacted"), Priority("Friend"), Priority("Guild")

	-- Ordered passes: recent (newest first) > friends > guild > Blizzard. Duplicates keep the
	-- first (highest-ranked) source. Inclusive search then merges them alphabetically.
	for _, name in ipairs(GetNewestFirst()) do Add(name, recentPriority) end
	for _, name in ipairs(Addressees.GetFriends()) do Add(name, friendPriority) end
	for _, name in ipairs(Addressees.GetGuild()) do Add(name, guildPriority) end
	for _, entry in ipairs(blizz) do
		if type(entry) == "table" then Add(entry.name, nil, entry) end
	end
	if ns.GetOption("inclusiveSearch") then
		sort(results, function(a, b) return Key(a.name) < Key(b.name) end)
	end

	while #results > maxResults do
		tremove(results)
	end
	return results
end

-- Install our source (custom mode) or Blizzard's original (Blizzard mode).
-- TAINT NOTE (§3.9 rule 4): this is the only write into a Blizzard table in this phase. It
-- goes through Blizzard's own setter, AutoCompleteEditBox_SetAutoCompleteSource, which
-- assigns SendMailNameEditBox.autoCompleteSource/.autoCompleteParams. Those fields are read
-- only by Blizzard_AutoComplete's insecure UI code (dropdown + tail highlight); nothing
-- protected (SendMail is not protected) runs from them. No edit-box script is replaced.
-- Restoring Blizzard mode re-installs the captured original function and parameters.
function Addressees.ApplyAutocompleteMode()
	local box = SendMailNameEditBox
	if not active or not box or not origSource then return end
	local params = origParams or {}
	if ns.GetOption("blizzardAutocomplete") then
		if box.autoCompleteSource ~= origSource then
			AutoCompleteEditBox_SetAutoCompleteSource(box, origSource, unpack(params))
		end
	elseif box.autoCompleteSource ~= Addressees.Source then
		AutoCompleteEditBox_SetAutoCompleteSource(box, Addressees.Source, unpack(params))
	end
end

-- ---------------------------------------------------------------------------
-- Popups (S4 right-click delete, S5 Add Name). Clear List uses ns.Confirm in Options.lua.
-- ---------------------------------------------------------------------------
local function RemoveAndReport(name)
	if Addressees.Remove(name) then
		ns.Print(format(L.NAME_REMOVED, name))
	end
end

local function AddFromText(text)
	local status, name = Addressees.AddManual(text)
	if status == "added" then
		ns.Print(format(L.NAME_ADDED, name))
	elseif status == "exists" then
		ns.ShowNotice(format(L.NAME_EXISTS, name))
	end
end

StaticPopupDialogs["MAILFUFU_CONFIRM_DELETE_NAME"] = {
	text = L.DELETE_NAME_Q,
	button1 = YES,
	button2 = NO,
	OnAccept = function(dialog, data)
		RemoveAndReport(data)
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["MAILFUFU_ADD_NAME"] = {
	text = L.ADD_NAME_PROMPT,
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = ADD_NAME_MAX_LETTERS,
	OnAccept = function(dialog)
		AddFromText(dialog:GetEditBox():GetText())
	end,
	EditBoxOnEnterPressed = function(editBox)
		local text = editBox:GetText()
		editBox:GetParent():Hide()
		AddFromText(text)
	end,
	EditBoxOnEscapePressed = function(editBox)
		editBox:GetParent():Hide()
	end,
	OnShow = function(dialog)
		dialog:GetEditBox():SetFocus()
	end,
	OnHide = function(dialog)
		dialog:GetEditBox():SetText("")
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

function Addressees.ConfirmRemove(name)
	StaticPopup_Show("MAILFUFU_CONFIRM_DELETE_NAME", name, nil, name)
end

function Addressees.PromptAdd()
	StaticPopup_Show("MAILFUFU_ADD_NAME")
end

-- ---------------------------------------------------------------------------
-- Dropdown menu (S4)
-- ---------------------------------------------------------------------------
local openMenu, menuOwner, pickName

local function OnRecentEnter(button, description)
	button.highlight:Show()
end

local function OnRecentLeave(button, description)
	button.highlight:Hide()
end

local function OnRecentClick(button, buttonName)
	local description = button:GetElementDescription()
	PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON)
	description:Pick(MenuInputContext.MouseButton, buttonName)
end

-- Initializer for MailFufuMenuButtonTemplate elements. Mirrors the stock button look
-- (MenuTemplates.CreateButton: MenuVariants.CreateFontString + CreateHighlight, highlight
-- toggled via button.OnEnter/OnLeave which MenuElementDescription:HandleOnEnter calls).
-- The frame comes from this addon's own pool, so registering the right button and setting
-- OnClick never leaks into Blizzard menus.
local function RecentInitializer(button, description, menu)
	local fontString = MenuVariants.CreateFontString(button)
	button.fontString = fontString
	fontString:SetTextToFit(description:GetData())
	MenuVariants.CreateHighlight(button)
	button.OnEnter = OnRecentEnter
	button.OnLeave = OnRecentLeave
	if button:IsMouseMotionFocus() then
		button.highlight:Show()
	end
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", OnRecentClick)
end

local function RecentResponder(name, menuInputData, menu)
	if menuInputData and menuInputData.buttonName == "RightButton" then
		Addressees.ConfirmRemove(name)
	elseif pickName then
		pickName(name)
	end
	return MenuResponse.CloseAll
end

-- Friend / guild entries: stock buttons, left-click only (right-click does nothing, S4).
local function SourceResponder(name)
	if pickName then pickName(name) end
	return MenuResponse.CloseAll
end

local function Generator(owner, root)
	root:SetScrollMode(MENU_MAX_ROWS * MENU_ROW_HEIGHT)

	for _, name in ipairs(Addressees.GetSorted()) do
		local element = root:CreateTemplate(MENU_BUTTON_TEMPLATE)
		element:SetData(name)
		element:AddInitializer(RecentInitializer)
		element:SetResponder(RecentResponder)
	end

	root:CreateButton(COLOR_ADD .. L.ADD_NAME .. COLOR_END, function()
		Addressees.PromptAdd()
		return MenuResponse.CloseAll
	end)

	local friendList = Addressees.GetFriends()
	local guildList = Addressees.GetGuild()
	if #friendList > 0 or #guildList > 0 then
		root:CreateDivider()
	end
	if #friendList > 0 then
		root:CreateTitle(L.FRIENDS_HEADER)
		for _, name in ipairs(friendList) do
			root:CreateButton("  " .. name, SourceResponder, name)
		end
	end
	if #guildList > 0 then
		root:CreateTitle(L.GUILD_HEADER)
		for _, name in ipairs(guildList) do
			root:CreateButton("  " .. name, SourceResponder, name)
		end
	end

	root:CreateDivider()
	root:CreateButton(COLOR_CLEAR .. L.CLEAR_FIELD .. COLOR_END, function()
		if pickName then pickName("") end
		return MenuResponse.CloseAll
	end)
end

function Addressees.IsMenuOpen()
	return openMenu ~= nil and openMenu:IsShown() and openMenu:GetOwnerRegion() == menuOwner
end

function Addressees.CloseMenu()
	if Addressees.IsMenuOpen() then
		openMenu:Close()
	end
	openMenu = nil
end

-- Toggle the dropdown under owner. onPick(name) receives the chosen name ("" = Clear Field).
function Addressees.ToggleMenu(owner, onPick)
	if Addressees.IsMenuOpen() then
		Addressees.CloseMenu()
		return
	end
	menuOwner, pickName = owner, onPick
	openMenu = MenuUtil.CreateContextMenu(owner, Generator)
	return openMenu
end

-- ---------------------------------------------------------------------------
-- Lifecycle and option reactions
-- ---------------------------------------------------------------------------
function Addressees.OnLogin()
	if Compat.IsLimitedMode() then return end
	if not SendMailNameEditBox then return end
	active = true

	Addressees.Sanitize()
	Addressees.AutoAddSelf()

	origSource = SendMailNameEditBox.autoCompleteSource
	origParams = SendMailNameEditBox.autoCompleteParams
	Addressees.ApplyAutocompleteMode()

	UpdateFriendEvents()
	UpdateGuildEvents()
end

function Addressees.OnMailShow()
	if not active then return end
	if ns.GetOption("includeFriends") then
		RequestFriends()
		friendsDirty = true
	end
	if ns.GetOption("includeGuild") then
		RequestGuild()
		guildDirty = true
	end
end

function Addressees.OnMailClosed()
	Addressees.CloseMenu()
end

function Addressees.OPTION_CHANGED(key)
	if not active then return end
	if key == "blizzardAutocomplete" then
		Addressees.ApplyAutocompleteMode()
	elseif key == "maxRecent" then
		Addressees.Sanitize()
	elseif key == "includeFriends" then
		UpdateFriendEvents()
		if ns.GetOption("includeFriends") then RequestFriends() end
	elseif key == "includeGuild" then
		UpdateGuildEvents()
		if ns.GetOption("includeGuild") then RequestGuild() end
	elseif key == "autoAddSelf" then
		Addressees.AutoAddSelf()
	end
end
