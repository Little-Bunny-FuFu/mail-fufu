-- Mail-fufu: Localization.lua
-- English strings. Every user-facing string goes through ns.L.
-- A missing key returns the key itself (metatable), so a typo shows up in-game as the
-- raw KEY_NAME instead of throwing.

local ADDON, ns = ...

local L = setmetatable({}, { __index = function(_, k) return k end })
ns.L = L

-- ---------------------------------------------------------------------------
-- General / chat
-- ---------------------------------------------------------------------------
L.ADDON_TITLE          = "Mail-fufu"
L.CHAT_PREFIX          = "Mail-fufu:"
L.NOT_IMPLEMENTED      = "Not implemented yet."
L.HOOK_TARGET_MISSING  = "%s hook target not found; that feature is disabled on this client."
-- Feature names substituted into HOOK_TARGET_MISSING.
L.HOOK_INBOX_UPDATE    = "Inbox update"
L.HOOK_OPENMAIL_UPDATE = "Open mail update"
L.HOOK_SEND_RESET      = "Send form reset"
L.HOOK_SEND_CAPTURE    = "Send capture"
L.HOOK_TAB_CLICK       = "Mail tab click"
L.EVENT_REGISTER_FAILED ="This client does not know the event %s; the feature that needs it is disabled."

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------
L.SLASH_USAGE          = "Usage: /mailfufu [%s]"
L.SLASH_UNKNOWN        = "Unknown command \"%s\"."

-- /mailfufu debug
L.DEBUG_HEADER         = "Client-shape report:"
L.DEBUG_BUILD          = "Build: version %s, build %s, date %s, interface %s"
L.DEBUG_PROJECT        = "WOW_PROJECT_ID: %s"
L.DEBUG_MIXIN_MAIL     = "Mixin mail UI (InboxFrame.Update present): %s"
L.DEBUG_TYPE           = "type(%s): %s"
L.DEBUG_REALM          = "Realm key: %s"
L.DEBUG_FACTION        = "Faction key: %s"
L.DEBUG_FOREVER        = "Forever client (interface 16001): %s"

-- ---------------------------------------------------------------------------
-- Options panel (§1.5). Labels OPT_<key>, tooltips OPT_<key>_TIP.
-- ---------------------------------------------------------------------------
L.OPT_HEADER_SEND      = "Send mail"
L.OPT_HEADER_INBOX     = "Inbox"
L.OPT_HEADER_CHAT      = "Chat output"
L.OPT_HEADER_HISTORY   = "Sent-mail history"

L.OPT_autoAddSelf          = "Add logged-in characters to recently-mailed list"
L.OPT_autoAddSelf_TIP      = "When a character logs in, add its name to the recently-mailed list of its realm and faction (if the list is not full)."
L.OPT_maxRecent            = "Maximum list length"
L.OPT_maxRecent_TIP        = "How many recently-mailed names to remember per realm and faction (8 to 40). Lowering it drops the oldest names."
L.OPT_includeFriends       = "Add friends to addressee list"
L.OPT_includeFriends_TIP   = "List your character friends and Battle.net friends who are online on a character of this game in the addressee dropdown and autocomplete."
L.OPT_includeGuild         = "Add guild members to addressee list"
L.OPT_includeGuild_TIP     = "List all guild members (online and offline) in the addressee dropdown and autocomplete."
L.OPT_inclusiveSearch      = "Use inclusive search"
L.OPT_inclusiveSearch_TIP  = "Merge recent names, friends and guild members into one alphabetical autocomplete list instead of searching them one after the other."
L.OPT_blizzardAutocomplete     = "Use standard Blizzard addressee search and autofill"
L.OPT_blizzardAutocomplete_TIP = "Leave the To field's autocomplete exactly as Blizzard ships it; recent names, friends and guild members are not suggested."
L.OPT_hideDropdown         = "Hide addressee dropdown button"
L.OPT_hideDropdown_TIP     = "Hide the arrow button next to the To field."
L.OPT_showOpenAll          = "Show Blizzard Open All button"
L.OPT_showOpenAll_TIP      = "Show Blizzard's own Open All button in the inbox."
L.OPT_rightClickTake       = "Right-click attachment retrieval"
L.OPT_rightClickTake_TIP   = "Right-click an inbox mail to take all of its money and items. Mail with cash on delivery is opened normally."
L.OPT_rightClickDelete     = "Right-click mail deletion"
L.OPT_rightClickDelete_TIP = "Right-click an inbox mail without money or items to delete it."
L.OPT_promptDeleteRead     = "Prompt for deletion of read mail"
L.OPT_promptDeleteRead_TIP = "Ask before a right-click deletes a mail you have already read. Unread mail always asks."
L.OPT_deletePendingAuction     = "Delete pending auction mail when getting all"
L.OPT_deletePendingAuction_TIP = "During Get Checked, delete marked auction-house mail that only announces pending funds."
L.OPT_printMoney           = "Output money received per mail"
L.OPT_printMoney_TIP       = "Print a chat line for every mail you take money from."
L.OPT_printTotal           = "Output total money received"
L.OPT_printTotal_TIP       = "Print the total money collected at the end of Get Checked."
L.OPT_tooltipText          = "Display mail text in inbox tooltip"
L.OPT_tooltipText_TIP      = "Show the mail's text when you hover a mail in the inbox.\n\n|cffff2020Warning:|r a mail is marked as read as soon as its tooltip shows, and the text can take a few seconds to appear."
L.OPT_historyLength        = "Number of history entries to store"
L.OPT_historyLength_TIP    = "How many sent mail items to remember in the history (0 turns the history off)."
L.OPT_historyMovable       = "Make history window movable"
L.OPT_historyMovable_TIP   = "Allow dragging the sent-mail history window."

L.CLEAR_LIST_LABEL     = "Recently-mailed list"
L.CLEAR_LIST_BUTTON    = "Clear List"
L.CLEAR_LIST_TIP       = "Remove every name from the recently-mailed list of this realm and faction."
L.CLEAR_LIST_CONFIRM   = "Clear the recently-mailed list for this realm and faction?"
L.CLEAR_LIST_DONE      = "Recently-mailed list cleared."
L.RESET_POS_LABEL      = "History window position"
L.RESET_POS_BUTTON     = "Reset Position"
L.RESET_POS_TIP        = "Move the sent-mail history window back to the centre of the screen."

-- ---------------------------------------------------------------------------
-- Send mail (P1). Keys reserved here so parallel phases do not collide.
-- ---------------------------------------------------------------------------
L.ADD_NAME             = "Add Name"
L.ADD_NAME_PROMPT      = "Name to add to the recently-mailed list:"
L.NAME_ADDED           = "%s added to the recently-mailed list."
L.NAME_EXISTS          = "%s is already in the recently-mailed list."
L.NAME_REMOVED         = "%s removed from the recently-mailed list."
L.DELETE_NAME_Q        = "Delete %s from the addressee list?"
L.CLEAR_FIELD          = "Clear Field"
L.FRIENDS_HEADER       = "Friends"
L.GUILD_HEADER         = "Guild Members"
L.DROPDOWN_TIP         = "Recently mailed, friends and guild members"
L.MONEY_SUBJECT        = "Money: %s"

-- ---------------------------------------------------------------------------
-- Inbox and take engine (P2)
-- ---------------------------------------------------------------------------
L.MARK_ALL             = "Mark All"
L.MARK_ALL_TIP         = "Mark all mail in inbox for attachment retrieval"
L.CLEAR_ALL            = "Clear All"
L.CLEAR_ALL_TIP        = "Clear all marked mail in inbox"
L.MARK_PAGE            = "Mark Page"
L.MARK_PAGE_TIP        = "Mark all mail on current page for attachment retrieval"
L.CLEAR_PAGE           = "Clear Page"
L.CLEAR_PAGE_TIP       = "Clear marks on all mail on current page"
L.GET_CHECKED          = "Get Checked"
L.GET_CHECKED_TIP      = "Get attachments from all marked mail in inbox"
L.BAGS_FULL            = "Your bags are full."
L.TIMEOUT              = "Unable to retrieve an attachment for 10 seconds. Check available bag space or unique items, then try again."
L.TOTAL                = "Total money received from attachments: %s"
L.RECEIVE_MONEY        = "You receive money: %s %s"
L.FROM                 = "from %s"
L.FROM_AUCTION         = "from auction of %s"
L.DELETE_Q             = "Delete mail from %s?"
L.DELETE_UNREAD_Q      = "Delete unread mail from %s?"

-- ---------------------------------------------------------------------------
-- Open mail (P3)
-- ---------------------------------------------------------------------------
L.TAKE_ALL             = "Take All"
L.FORWARD              = "Forward"
L.FORWARD_PREFIX       = "FW:"
L.MAIL_TEXT_HEADER     = "Mail Text"
L.NO_TEXT              = "<No Text>"

-- ---------------------------------------------------------------------------
-- History (P4)
-- ---------------------------------------------------------------------------
L.HISTORY_TITLE        = "Mail-fufu: sent mail history"
L.HISTORY_EMPTY        = "No messages sent"
L.HISTORY_ALL_REALMS   = "All realms"
L.SENT_LINE            = "Message to %s with the subject \"%s\" sent."
L.LAST_NONE            = "No mail sent yet."
L.HINT_LEFT            = "Left-click: sent-mail history"
L.HINT_RIGHT           = "Right-click: options"

-- P2 (TakeEngine/Inbox)
L.OPEN_ALL_BUSY        = "Blizzard's Open All is still running; wait for it to finish."
L.INBOX_CHANGED        = "The inbox changed while taking attachments; stopped. Click again to continue."

-- P3 (OpenMail)
L.TAKE_ALL_TIP         = "Take all money and items attached to this mail."
L.FORWARD_TIP          = "Copy this mail's subject and text into a new mail. Attachments are not forwarded."

-- P4 (History)
L.HISTORY_LINE1        = "%d. %s, %s  to: %s"
L.HISTORY_LINE2        = "subject: %s"
L.HISTORY_LAST_TITLE   = "Last sent mail"
L.HISTORY_TT_DATE      = "Date"
L.HISTORY_TT_TO        = "To"
L.HISTORY_TT_FROM      = "From"
L.HISTORY_TT_SUBJECT   = "Subject"
L.HISTORY_POS_RESET    = "History window position reset."
L.LAST_LINE            = "Last sent mail: %s, from %s to %s, subject \"%s\"."
-- Attachments logged with each sent mail (items, money, C.O.D.).
L.HISTORY_LINE3        = "attachments: %s"
L.HISTORY_NO_ATTACH    = "no attachments"
L.HISTORY_MORE         = "+%d more"
L.HISTORY_MONEY        = "money: %s"
L.HISTORY_COD          = "C.O.D.: %s"
L.HISTORY_TT_ITEMS     = "Attachments"
L.HISTORY_TT_MONEY     = "Money"
L.HISTORY_TT_COD       = "C.O.D."
L.LAST_ATTACH          = "Attachments: %s"
