-- Mail-fufu luacheck config (adapted from Bartender4-fufu/.luacheckrc).
-- Keep luacheck at 0 warnings: add every Blizzard global a new phase references to
-- read_globals, and every global the addon writes to globals.
std = "lua51"
max_line_length = false
exclude_files = {
	".luacheckrc",
	"tests",
}

ignore = {
	"211", -- Unused local variable
	"212", -- Unused argument
	"213", -- Unused loop variable
	"311", -- Value assigned to a local variable is unused
	"542", -- empty if branch
}

-- Globals the addon writes (or mutates fields of).
globals = {
	"MailFufu",
	"MailFufuDB",
	"MailFufuHistory",
	"StaticPopupDialogs",
	"SLASH_MAILFUFU1",
	"SlashCmdList",
}

-- Blizzard globals the addon reads.
read_globals = {
	"_G",

	-- Lua / WoW string and table helpers
	"format",
	"strlower",
	"strupper",
	"strtrim",
	"strsplit",
	"tinsert",
	"tremove",
	"wipe",
	"geterrorhandler",
	"hooksecurefunc",

	-- Client info
	"GetBuildInfo",
	"GetRealmName",
	"UnitFactionGroup",
	"UnitFullName",
	"WOW_PROJECT_ID",
	"GameLimitedMode_IsActive",
	"InputUtil",

	-- Frames and UI
	"CreateFrame",
	"DEFAULT_CHAT_FRAME",
	"PlaySound",
	"SOUNDKIT",
	"StaticPopup_Show",

	-- Mail UI (both client shapes, see Compat.lua)
	"InboxFrame",
	"InboxFrame_Update",
	"OpenMailFrame",
	"OpenMail_Update",

	-- Settings API (Blizzard_Settings_Shared)
	"Settings",
	"CreateSettingsButtonInitializer",
	"CreateSettingsListSectionHeaderInitializer",
	"MinimalSliderWithSteppersMixin",

	-- GlobalStrings
	"OKAY",
	"YES",
	"NO",

	-- P2 (TakeEngine/Inbox)
	"MailFrame",
	"OpenAllMail",
	"InboxTooMuchMail",
	"ATTACHMENTS_MAX",
	"INBOXITEMS_TO_DISPLAY",
	"OPEN_ALL_MAIL_BUTTON_OPENING",
	"UNKNOWN",
	"C_Mail",
	"C_Container",
	"C_Timer",
	"GameMenuFrame",
	"HideUIPanel",
	"InCombatLockdown",
	"SettingsPanel",
	"GetTime",
	"GetInboxNumItems",
	"GetInboxHeaderInfo",
	"GetInboxInvoiceInfo",
	"GetInboxItem",
	"HasInboxItem",
	"TakeInboxItem",
	"TakeInboxMoney",
	"DeleteInboxItem",
	"InboxItemCanDelete",
	"GetMoneyString",
	"IsModifiedClick",
	"GameTooltip",
	"GameTooltip_SetTitle",
	"GameTooltip_AddNormalLine",
	"GameTooltip_Hide",
	"StaticPopup_Hide",

	-- P1 (Addressees/SendMail)
	"ACCEPT",
	"Ambiguate",
	"AutoCompleteEditBox_SetAutoCompleteSource",
	"BNET_CLIENT_WOW",
	"BNGetNumFriends",
	"C_BattleNet",
	"C_Club",
	"C_FriendList",
	"C_GuildInfo",
	"CANCEL",
	"COPPER_AMOUNT_SYMBOL",
	"COPPER_PER_GOLD",
	"COPPER_PER_SILVER",
	"Enum",
	"GetLocale",
	"GetNumGuildMembers",
	"GOLD_AMOUNT_SYMBOL",
	"IsInGuild",
	"MailFrameTab_OnClick",
	"MenuInputContext",
	"MenuResponse",
	"MenuUtil",
	"MenuVariants",
	"MoneyInputFrame_GetCopper",
	"OpenAllBags",
	"ATTACHMENTS_MAX_SEND",
	"HasSendMailItem",
	"GetSendMailItem",
	"GetSendMailItemLink",
	"SendMailCODButton",
	"SendMailFrame",
	"SendMailFrame_Reset",
	"SendMailFrame_SendMail",
	"SendMailMailButton",
	"SendMailMoney",
	"SendMailNameEditBox",
	"SendMailNameEditBoxMiddle",
	"SendMailSubjectEditBox",
	"SILVER_AMOUNT_SYMBOL",
	"UnitName",

	-- P3 (OpenMail)
	"GetInboxText",
	"OpenMailHorizontalBarLeft",
	"OpenMailReplyButton",
	"OpenMailMoneyButton",
	"OpenMailSubject",
	"SendMailBodyEditBox",

	-- Layout spec 2026-11-09 (OpenMail Take All room-making)
	"OpenMailAttachmentText",
	"OpenMailScrollChildFrame",
	"OpenMailScrollFrame",
	"OpenStationeryBackgroundLeft",
	"OpenStationeryBackgroundRight",

	-- P4 (History)
	"CreateDataProvider",
	"CreateScrollBoxListLinearView",
	"date",
	"GameTooltip_AddInstructionLine",
	"GetMinimapZoneText",
	"GetRealZoneText",
	"ScrollUtil",
	"time",
	"UIParent",
	"UISpecialFrames",
}
