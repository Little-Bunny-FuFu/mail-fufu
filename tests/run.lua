-- Mail-fufu self-check for the pure logic. Run from the repo root: lua tests/run.lua
-- Loads the real addon files against a handful of stubbed WoW globals; no framework.

-- WoW global aliases the files use at load time or inside the functions under test.
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strupper, strlower, format = string.upper, string.lower, string.format
tinsert, tremove = table.insert, table.remove
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
GetLocale = function() return "enUS" end
StaticPopupDialogs = {}
COPPER_PER_GOLD, COPPER_PER_SILVER = 10000, 100
GOLD_AMOUNT_SYMBOL, SILVER_AMOUNT_SYMBOL, COPPER_AMOUNT_SYMBOL = "g", "s", "c"

local inbox = {}                                   -- { { sender, subject }, ... }
InboxFrame = {}
GetInboxNumItems = function() return #inbox, #inbox end
GetInboxHeaderInfo = function(i)
	local m = inbox[i]
	if m then return nil, nil, m[1], m[2] end
end

local options = { historyLength = 100 }
local ns = {
	L = setmetatable({}, { __index = function(_, k) return k end }),
	Compat = { RealmKey = function() return "Realm" end, FactionKey = function() return "Alliance" end },
	history = { entries = {} },
	GetOption = function(key) return options[key] end,
	RegisterModule = function(_, mod) return mod end,
	RegisterSlash = function() end,
}
for _, file in ipairs({ "Addressees.lua", "SendMail.lua", "TakeEngine.lua", "Inbox.lua", "History.lua" }) do
	assert(loadfile(file))("Mail-fufu", ns)
end

local function eq(got, want, what)
	assert(got == want, ("%s: got %s, want %s"):format(what, tostring(got), tostring(want)))
end

-- NameCase: first letter up, rest down, realm suffix untouched.
local NameCase = ns.Addressees.NameCase
eq(NameCase("  bOB "), "Bob", "NameCase trims and folds")
eq(NameCase("bob-Area52"), "Bob-Area52", "NameCase keeps the realm")
eq(NameCase(""), "", "NameCase empty")
eq(NameCase(nil), "", "NameCase non-string")

-- ShortMoney: zero parts are left out.
local ShortMoney = ns.SendMail.ShortMoney
eq(ShortMoney(120503), "12g 5s 3c", "ShortMoney all parts")
eq(ShortMoney(10000), "1g", "ShortMoney gold only")
eq(ShortMoney(7), "7c", "ShortMoney copper only")

-- History.Truncate: keeps the newest n, in order.
local entries = ns.history.entries
local function fill(n) wipe(entries) for i = 1, n do entries[i] = i end end
fill(5) ns.History.Truncate(2)
eq(#entries, 2, "Truncate length") eq(entries[1], 4, "Truncate keeps newest") eq(entries[2], 5, "Truncate order")
fill(3) ns.History.Truncate(5)
eq(#entries, 3, "Truncate under the cap is a no-op")
fill(3) ns.History.Truncate(0)
eq(#entries, 0, "Truncate 0 empties")

-- Mark carry-over (Inbox.Refresh -> RemapMarks): a mark follows its mail, not its index.
local marks = ns.Inbox.marks
local function marked() local s = "" for i = 1, #marks do s = s .. (marks[i] and "x" or ".") end return s end
inbox = { { "A", "1" }, { "B", "2" }, { "C", "3" } }
ns.Inbox.Refresh()
marks[2] = true
eq(marked(), ".x.", "marks start")
inbox = { { "B", "2" }, { "C", "3" } }                              -- first mail removed
ns.Inbox.Refresh()
eq(marked(), "x.", "mark follows after a removal above it")
inbox = { { "N", "0" }, { "B", "2" }, { "C", "3" } }                -- new mail at the front
ns.Inbox.Refresh()
eq(marked(), ".x.", "mark follows after a front insertion")
inbox = { { "N", "0" }, { "B", "2" }, { "C", "3" }, { "Old", "9" } } -- older mail appended
ns.Inbox.Refresh()
eq(marked(), ".x..", "appended mail starts unmarked")
inbox = { { "N", "0" }, { "C", "3" }, { "Old", "9" } }              -- the marked mail is gone
ns.Inbox.Refresh()
eq(marked(), "...", "mark dies with its mail")

print("ok")
