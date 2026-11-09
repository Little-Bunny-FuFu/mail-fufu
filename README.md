# Mail-fufu

A mail window helper for **World of Warcraft retail (12.1.x)** and the **WoW Forever
client (1.60.x, Interface 16001)**: remembers the people you mail, batch-collects
attachments, forwards mail text, and keeps a log of the mail you sent.

Mail-fufu is a clean-room, library-free re-implementation of the EasyMail feature set.
It contains no EasyMail code, strings or artwork. It only post-hooks Blizzard's mail UI
(`hooksecurefunc` / `HookScript`) and resolves every hook target by feature detection,
so the same files run on both client shapes (the global-function mail UI of 12.1.x and
the mixin mail UI of WoW Forever / 12.2).

> Status: **0.1.0, verified in-game on retail 12.1.x and WoW Forever 1.60.x (2026-11-09).** Test plan in
> `../Mail-fufu - Design plan (2026-11-09).md` section 5 for what to verify in-game.

## Features

### Send mail
- **Last addressee per character.** The To field is prefilled with the name this
  character last mailed, highlighted so typing replaces it.
- **Recently-mailed list** per realm and faction (8 to 40 names, default 15, oldest
  dropped). Opened from the arrow button beside the To field. Left-click fills the field,
  right-click removes the name, "Add Name" adds one by hand, "Clear Field" empties the field.
- **Friends and guild members** can be added to the dropdown and the autocomplete (both
  off by default).
- **Autocomplete** plugs the recent/friends/guild names into Blizzard's own To-field
  suggestions (inline tail highlight plus the suggestion list). "Use standard Blizzard
  autofill" switches back to the stock behaviour. "Inclusive search" merges all sources
  into one alphabetical list.
- **Money subject.** Entering gold/silver/copper with an empty subject writes
  `Money: 12g 5s`; a hand-typed subject is never overwritten.
- **Bags open** when you click the Send Mail tab.

### Inbox
- **Checkboxes** on every inbox row, kept across pages.
- **Toolbar:** Mark All, Clear All, Mark Page, Clear Page and **Get Checked**, which
  collects every money and item attachment from the marked mails. COD and GM mails are
  skipped. Optionally deletes pending-auction invoice mails.
- The collection engine works by mail index like Blizzard's Open All, stops when the
  mailbox closes or a row is clicked, aborts if one attachment cannot be taken for 10
  seconds or the bags are full, and stops safely if the inbox changes under it.
- **Right-click** a row to take its attachments, or to delete a text-only mail (unread mail
  always asks first; read mail asks unless you turn the prompt off). Both off by default.
- **Mail text in the inbox tooltip** (off by default; reading the text marks the mail read).
- **Open All** button can be hidden; it is disabled while the inbox is empty.

### Open mail
- **Take All** takes every attachment of the open mail (disabled on COD mail until you
  accept the COD).
- **Forward** opens a new mail with `FW: <subject>` and the original text. Attachments
  cannot be forwarded by the API; the original mail stays open beside the send form.
- **Chat lines** for money received per mail (auction sales named by item) and the batch
  total.

### History
- Every sent mail is logged (addressee, subject, attached items with counts, money or
  C.O.D. amount, sender, zone, time). Hover a history row to see every attachment. The history window
  (left-click the envelope in the mail window's corner) lists them newest first for the
  current realm, with an "All realms" toggle. Right-click the envelope opens the options.
- History length is configurable (0 disables it) and lives in its own SavedVariable, so
  resetting options never clears it.

Dropped from the EasyMail feature set because the client provides it or it no longer
applies: mouse-wheel inbox paging, the Classic send-editbox fixes, the Mists calendar
button relocation.

## Slash commands

| Command | Action |
|---|---|
| `/mailfufu` | Open the options panel |
| `/mailfufu history` | Toggle the sent-mail history window |
| `/mailfufu last` | Print the last sent mail |
| `/mailfufu debug` | Print the client-shape report (build, mail UI shape, realm key) |

## Options

Game Menu > Options > AddOns > Mail-fufu. "Defaults" resets the options only; it never
clears the recently-mailed list or the sent-mail history. The "Clear recently-mailed list"
button clears the list for the current realm and faction only.

## Installing

Copy the `Mail-fufu` folder into `Interface\AddOns` of the retail or Forever client, or
run the workspace deploy script:

```
deploy.ps1 -AddonName Mail-fufu -DestPath "<path to Interface\AddOns>"
```

SavedVariables: `MailFufuDB` (options, per-realm addressee lists, window position) and
`MailFufuHistory` (sent-mail log).

## Module contract (for contributors)

Load order is the TOC order: `Localization`, `Compat`, `Core`, `Options`, `Addressees`
(XML template + Lua), `SendMail`, `TakeEngine`, `Inbox`, `OpenMail`, `History`. Each
feature file registers itself with `ns.RegisterModule(name, Mod)` and may define
`Mod.OnLogin()`, `Mod.OnMailShow()`, `Mod.OnMailClosed()` and handlers named after events
or addon messages (`Mod.MAIL_INBOX_UPDATE()`, `Mod.OPTION_CHANGED(key, value)`,
`Mod.MAIL_SENT(to, subject)`). Core calls them without a `self` argument, in TOC order.
All hook targets that differ between clients go through `Compat.lua`.

## License

All rights reserved.
