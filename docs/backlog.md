# Backlog

Every task Adi gives is tracked here and in Linear (project "AU-PluginHelper"). IDs (BL-01, BL-02...) are never reused.
Priority: **P1** this week, **P2** next, **P3** someday. Severity: **Critical**, **High**, **Medium**, **Low**.
Layout (2026-10-13): `- [ ]` open in **Inbox**, `- [~]` in progress in **Now**, `- [x]` finished in **Done** (newest first, with the date), `- [-]` dropped (with the reason, stays where it was). Every line is `- [ ] **BL-n** [LINK] `P1 · High` **Title:** what and why`; the link appears after `--send`. Nothing is ever deleted from this file.
After adding an item run `node ~/.claude/scripts/backlog-linear.mjs --send`; `--start BL-n` when work begins, `--done BL-n` when it is finished, `--drop BL-n "why"` to drop it.

## Inbox

- [ ] **BL-01** `P1 · High` **AU Plugin Picker app for Logic Pro:** native SwiftUI background app; global hotkey and menu-bar item open a popup listing every installed Audio Unit with a cached screenshot of its UI, name, manufacturer, category and scanned info (incl. best feature); search as you type, sort by name/category/manufacturer/recent/favorites, arrows and Esc; Enter places the plugin in the first empty insert slot in Logic Pro. Asked by Adi, 2026-10-30.

## Now

## Done
