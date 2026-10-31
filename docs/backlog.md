# Backlog

Every task Adi gives is tracked here and in Linear (project "AU-PluginHelper"). IDs (BL-01, BL-02...) are never reused.
Priority: **P1** this week, **P2** next, **P3** someday. Severity: **Critical**, **High**, **Medium**, **Low**.
Layout (2026-10-13): `- [ ]` open in **Inbox**, `- [~]` in progress in **Now**, `- [x]` finished in **Done** (newest first, with the date), `- [-]` dropped (with the reason, stays where it was). Every line is `- [ ] **BL-n** [LINK] `P1 · High` **Title:** what and why`; the link appears after `--send`. Nothing is ever deleted from this file.
After adding an item run `node ~/.claude/scripts/backlog-linear.mjs --send`; `--start BL-n` when work begins, `--done BL-n` when it is finished, `--drop BL-n "why"` to drop it.

## Inbox

- [~] **BL-50** `P2 · Medium` **Free plugin info without an API key:** offer a free model for Look Up Info next to the paid one, ideally the Mac's own built-in model (no download), else a small downloadable one. Adi, 2026-10-31. Built-in model shipped in 0.7.0; the downloadable model is built behind the LOCAL_MODEL switch and waits for the Metal toolchain.
- [~] **BL-20** `P1 · High` **Make the app beautiful:** full design pass on every screen (library, quick picker, info panel, mini window, settings, welcome tour, progress window) so it feels like a finished, premium Mac app. Adi, 2026-10-30, while he is away for an hour.
- [x] **BL-17** `P1 · Medium` **Design pass with the taste skill:** title on the bar with its own mark (no bubble), no gradients or resting shadows, no uppercase labels or tinted icon circles, one neutral card for Logic plugins, mini mode as one search line and two rows. Adi, 2026-10-30. · done 2026-10-30
## Now

- [~] **BL-73** `P1 · High` **Crash reports to Goldi:** after AG PlugFinder closed unexpectedly, the next launch offers "Send the report to Goldi"; also a Send error log button any time. Reports go to the shared database for Adi to read. Adi, 2026-10-31.
- [~] **BL-71** `P2 · Medium` **Shared plugin database:** users can choose to share plugin pictures and info; Adi approves them; everyone downloads them so the same plugin is never scanned twice. Neon database (Adi's choice) behind a small API with auth; pictures in the database or blob storage. Adi, 2026-10-31. Collecting shipped in 0.9.0 (upload on by default, approval with `npm run review`); downloading approved pictures still to build.
- [~] **BL-70** `P1 · Medium` **Clear a track with Logic's own command:** Remove All Effect Plug-ins from the channel strip's Setting menu in one step instead of one by one; also Bypass All, Remove Bypassed and Remove All Sends. Adi, 2026-10-31.
- [~] **BL-69** `P1 · Medium` **Channel format, Auto or Ask me:** when Logic offers a plugin in several versions (Mono, Stereo, Mono to Stereo, Dual Mono), Auto picks the one that fits the track and Ask me leaves Logic's choice open; each plugin can have its own. Inspired by PlugSearch's Channel Mode. Adi, 2026-10-31.
- [~] **BL-68** `P1 · High` **Faster inserting into Logic:** go straight down Logic's plug-in menu to the plugin (maker, then name) and remember the path, wait only as long as Logic needs instead of fixed pauses. Adi asked why PlugSearch is faster, 2026-10-31.
- [ ] **BL-64** `P3 · Low` **Logic in other languages:** recognise Logic's slots and menus when Logic runs in German, French and other languages (PlugSearch does). Adi, 2026-10-31.
- [~] **BL-65** `P1 · Medium` **Point at a slot and press a key:** with the pointer over a slot in Logic, a key inserts, replaces or removes right there, with a highlight on the slot. Adi, 2026-10-31.
- [ ] **BL-66** `P2 · Medium` **Drag a plugin from AG PlugFinder onto Logic:** drop on a slot, a track header, or the empty area to make a new track. Adi, 2026-10-31.
- [ ] **BL-67** `P2 · Low` **Hide plugins Logic won't load:** read which plugins Logic accepts and hide the rest. Adi, 2026-10-31.
- [~] **BL-47** `P1 · High` **Publish 0.5.0 so Check for Update finds it:** make the AG-PlugFinder repo public (Adi chose this over a separate releases repo) and publish a signed, notarized 0.5.0 release with every feature since 0.4.0. Adi, 2026-10-31.
- [~] **BL-05** `P1 · Medium` **One-click updater like AGenda:** check for a new version, show "Update available" with what's new, install with one click and restart. Adi, 2026-10-30.

## Done

- [x] **BL-74** `P2 · Medium` **Shortcuts for the track panel actions:** Save as chain, Remove all effects, Remove the ones turned off and Remove all sends can each get a key in Settings > Shortcuts. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-72** `P1 · High` **Plugin popups during the picture scan:** a plugin's own popup ("Too many parameters in process", Absynth 5 MFX) is closed at once and noted; a plugin that failed is not tried again on every scan. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-63** `P2 · Low` **Menu bar icon:** the app's own three-bar mark instead of a generic puzzle piece. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-62** `P1 · Medium` **Install with Homebrew:** tap adigold/homebrew-tap with the ag-plugfinder cask, README steps, release.sh updates the cask on every release. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-61** `P2 · Medium` **Magnifier on the info panel picture:** a magnifier on hover; click opens the picture large, zoom with pinch or double-click, Esc or a click outside closes it. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-60** `P2 · Medium` **Drag plugins onto collections:** drag a plugin's picture onto a collection chip at the top to add it to that collection. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-59** `P1 · High` **Release 0.6.2:** automatic update check on open, new instrument track named after the instrument. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-58** `P1 · High` **Instrument on a track that has one:** choosing an instrument while the selected track already has one makes a new instrument track named after it, for Logic's own instruments and any other instrument (tested with DLSMusicDevice). Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-57** `P1 · Medium` **Check for updates when the app opens:** check a few seconds after opening and when coming back to the app (at most hourly); a new version opens its What's New window with Install and Restart, once per version. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-56** `P1 · Medium` **Drag to reorder the track's effects:** drag effects in the track panel and the order changes in Logic too. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-55** `P1 · Medium` **Share AG PlugFinder:** a designed share window (not the generic Mac one) with one-click X, WhatsApp, Messages, Instagram, Telegram, Facebook, LinkedIn, Email and Copy link, plus a social preview image so shared GitHub links show a nice card. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-54** `P1 · High` **Release 0.6.0:** shortcuts, Hyper key, What's New window, size slider, new instrument track, categories by default. Adi wants to see the What's New window after updating. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-53** `P1 · Medium` **A great GitHub README:** explain everything the app does and what is new, with a GIF and screenshots taken from the app's own windows, then push. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-52** `P1 · Medium` **Instrument on a track without one:** loading an instrument while an audio or aux track is selected makes a new instrument track and loads it there. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-51** `P1 · High` **Shortcuts in Settings:** map every action (open window, quick picker, mini window, track panel, open/close plugin windows, remove last, number keys) to your own key combos, including a Hyper key, with Caps Lock usable as Hyper. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-49** `P1 · High` **A designed What's New window:** replace the plain list of release notes with a window of cards (icon, title, detail), a New badge on update announcements, and the same design after an update. Categories become the default chip row. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-48** `P1 · Medium` **Screenshot size slider:** a slider on the right, under the top bar, that sets how big the plugin pictures are, any size between small and extra large. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-46** `P1 · Medium` **Category shortcuts above the grid:** a Settings option to show category buttons (EQ, Reverb, Delay...) in the chip row, next to collections or on their own, so one click shows only that category. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-45** `P1 · Medium` **Hotkey opens the big window:** Control Option P opens the main library window instead of the small popup. Adi, 2026-10-30. · done 2026-10-31
- [x] **BL-44** `P2 · Low` **Plugin window keys:** close every open plugin window, and open all plugins of the track side by side. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-43** `P2 · Medium` **New track with an instrument:** create a new software instrument track with the chosen instrument loaded. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-42** `P2 · Medium` **Reverb as a send:** set up a bus with the chosen effect and a send from the track in one step. Test on a scratch project first. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-41** `P2 · Medium` **Add to several tracks at once:** insert a plugin or chain on every selected track. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-40** `P1 · Medium` **Find where a plugin is used:** list every track in the project that has a plugin and jump to that track. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-39** `P2 · Medium` **Insert before or after:** place a plugin before or after another one on the track, not only in the first free slot. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-38** `P1 · Medium` **Remove or clear:** remove the last added plugin, or clear all effects from the track. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-37** `P1 · High` **Save the track as a chain:** read the selected track's plugins and save them as a chain. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-36** `P1 · Medium` **Replace a plugin on the track:** "Replace on track" puts the new plugin into the same slot and removes the old one, keeping the chain order. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-35** `P1 · High` **See the track's plugins:** the app shows the plugins already on the selected Logic track, in order, each with an on/off switch. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-24** `P1 · High` **An amazing updater:** a beautiful update window with what is new, live download progress, clear steps (downloading, checking, installing, restarting), then the app installs the verified version, quits and opens again by itself. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-25** `P1 · High` **Plugin chains:** save a chain of plugins (for example EQ, Compressor, DeEsser, Reverb) and drop the whole chain on the selected track with one key. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-26** `P1 · High` **Number hotkeys for favorites:** pin plugins to Control Option 1 to 9 and insert them from anywhere in Logic without opening the window. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-27** `P1 · Medium` **Search by what it does:** search matches each plugin's description and best feature, so "warm tape saturation" finds the right plugins. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-28** `P2 · Medium` **More like this:** the info panel shows similar plugins you own (same kind and category). Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-29** `P2 · Medium` **Collections:** your own collections like "Mix bus" or "Lo-fi", shown as chips above the grid; add plugins with a right click. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-30** `P2 · Medium` **Personal notes per plugin:** write your own tips for each plugin right in the info panel. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-31** `P2 · Medium` **Usage stats:** count every insert; sort by most used and see plugins you never use. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-32** `P3 · Low` **Plugin cleanup report:** find plugins installed twice and how much disk space each maker takes. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-33** `P2 · Medium` **Suggestions for the selected track:** read the selected Logic track's name and show matching plugins first (vocals, drums, bass, guitar, keys). Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-34** `P3 · Low` **Sync across Macs:** favorites, collections, chains, notes, pins and hidden plugins sync through iCloud Drive. Adi, 2026-10-31. · done 2026-10-31
- [x] **BL-23** `P2 · Medium` **Smooth search results:** while typing, plugins that no longer match fade and shrink away and the rest glide into place, instead of popping. Adi, 2026-10-30. · done 2026-10-31
- [x] **BL-22** `P2 · Medium` **Download the plugin pack from GitHub:** new installs can download a pack of plugin pictures and looked-up info from the GitHub release instead of capturing everything themselves. Adi, 2026-10-30. · done 2026-10-31
- [x] **BL-21** `P1 · High` **Ship Logic's plugin pictures inside the app:** capture every Logic plugin once and bundle the pictures in the app, so other users never need to take them. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-15** `P1 · Medium` **Screenshots of Logic's own plugins:** capture them inside Logic (scratch track in an empty project, open each plugin window, capture, remove), since they cannot run outside Logic. Needs Insert in Logic working first (BL-12). Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-16** `P1 · High` **Instruments go to the instrument slot, effects to the inserts:** a software instrument must land in the track's instrument slot, an audio effect in the first empty audio insert. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-14** `P1 · Medium` **Arrow keys in the main window:** arrows browse and select, Return inserts, like the popup. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-19** `P2 · Medium` **Right-click in the Plugin List:** per plugin, per group and for all plugins: take or retake screenshots, look up info, clear a screenshot or info, clear the screenshot cache, show only this group. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-12** `P1 · High` **Fix Insert in Logic and redesign the info panel:** the Insert in Logic button does nothing for Adi; keep it always visible at the top of the panel and give the panel a nicer design. Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-01** `P1 · High` **AU Plugin Picker app for Logic Pro:** native SwiftUI background app; global hotkey and menu-bar item open a popup listing every installed Audio Unit with a cached screenshot of its UI, name, manufacturer, category and scanned info (incl. best feature); search as you type, sort by name/category/manufacturer/recent/favorites, arrows and Esc; Enter places the plugin in the first empty insert slot in Logic Pro. Asked by Adi, 2026-10-30. · done 2026-10-30
- [x] **BL-18** `P1 · Medium` **Never re-capture screenshots we already have:** the camera button captures only plugins with no picture; retaking one is a right-click on that plugin. Adi, 2026-10-30. · done 2026-10-30
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
