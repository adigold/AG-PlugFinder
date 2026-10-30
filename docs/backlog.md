# Backlog

Every task Adi gives is tracked here and in Linear (project "AU-PluginHelper"). IDs (BL-01, BL-02...) are never reused.
Priority: **P1** this week, **P2** next, **P3** someday. Severity: **Critical**, **High**, **Medium**, **Low**.
Layout (2026-10-13): `- [ ]` open in **Inbox**, `- [~]` in progress in **Now**, `- [x]` finished in **Done** (newest first, with the date), `- [-]` dropped (with the reason, stays where it was). Every line is `- [ ] **BL-n** [LINK] `P1 · High` **Title:** what and why`; the link appears after `--send`. Nothing is ever deleted from this file.
After adding an item run `node ~/.claude/scripts/backlog-linear.mjs --send`; `--start BL-n` when work begins, `--done BL-n` when it is finished, `--drop BL-n "why"` to drop it.

## Inbox

- [ ] **BL-15** `P1 · Medium` **Screenshots of Logic's own plugins:** capture them inside Logic (scratch track in an empty project, open each plugin window, capture, remove), since they cannot run outside Logic. Needs Insert in Logic working first (BL-12). Adi, 2026-10-30.
## Now

- [~] **BL-12** `P1 · High` **Fix Insert in Logic and redesign the info panel:** the Insert in Logic button does nothing for Adi; keep it always visible at the top of the panel and give the panel a nicer design. Adi, 2026-10-30.
- [~] **BL-14** `P1 · Medium` **Arrow keys in the main window:** arrows browse and select, Return inserts, like the popup. Adi, 2026-10-30.
- [~] **BL-01** `P1 · High` **AU Plugin Picker app for Logic Pro:** native SwiftUI background app; global hotkey and menu-bar item open a popup listing every installed Audio Unit with a cached screenshot of its UI, name, manufacturer, category and scanned info (incl. best feature); search as you type, sort by name/category/manufacturer/recent/favorites, arrows and Esc; Enter places the plugin in the first empty insert slot in Logic Pro. Asked by Adi, 2026-10-30.
- [~] **BL-05** `P1 · Medium` **One-click updater like AGenda:** check for a new version, show "Update available" with what's new, install with one click and restart. Adi, 2026-10-30.

## Done

- [x] **BL-13** `P1 · Medium` **Keep the window on top, mini mode:** a pin that keeps the main window above Logic, and a compact mini mode that floats on top. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-11** `P1 · High` **First-run onboarding for permissions:** on first install, a friendly step-by-step window gets every permission (Accessibility for Logic, open at login, optional API key) approved before the app starts working. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-10** `P2 · Low` **App title centered at the top:** show "AG PlugFinder" in the middle of the main window's top bar. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-09** `P1 · Medium` **Detailed screenshot progress window:** replace the thin progress line with a window showing each plugin, its preview, done/failed counts and time left. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-08** `P1 · Medium` **Version and update button, top right:** show the installed version and "Check for update" in the app's top right; say "You're updated." or "A new update is available." so a friend running the app sees new releases. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-07** `P1 · Medium` **Rename the app to an AG name:** Adi wants a name tied to him (AG); he will then give the GitHub repo for updates. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-06** `P2 · Low` **Report app and data size:** tell Adi how big the app is and how much data it stores. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-04** `P1 · Medium` **Browser view options:** toggle the info under each tile, thumbnail size (small/medium/large), remove the category chips and title, grid or list, sort name/maker/recent, favorites only. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-03** `P1 · Medium` **Plugin list editor in Settings:** hide or show plugins by group (manufacturer, category, format, type) so the browser shows only what Adi wants, like PlugSearch. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-02** `P1 · High` **Scan Logic's own plugins:** list Logic Pro's built-in plugins (ChromaVerb, Channel EQ, Alchemy...) alongside the Audio Units, so the picker shows everything Logic offers. Adi, 2026-10-30. · done 2026-10-30

## Notes
- 2026-10-30 BL-01: app built and installed; scan, cached screenshots (29/30), popup, search and sorts verified. Still to verify live: insert into Logic (Accessibility), info lookup (API key), notarized release (`scripts/release.sh`).
