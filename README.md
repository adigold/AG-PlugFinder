<p align="center">
  <img src="docs/images/demo.gif" width="760" alt="AG PlugFinder: type to find a plugin, the rest fade away">
</p>

<h1 align="center">AG PlugFinder</h1>

<p align="center">
  <b>Find any plugin by how it looks, and put it on your Logic Pro track in one keystroke.</b><br>
  Every plugin you own, with a picture of its real window, a search that understands what you mean,<br>
  and full control of the selected track's plugins without touching the mouse.
</p>

<p align="center">
  <a href="https://github.com/adigold/AG-PlugFinder/releases/latest/download/AG-PlugFinder.dmg"><b>Download for Mac</b></a>
  &nbsp;·&nbsp; macOS 15 or later &nbsp;·&nbsp; Logic Pro &nbsp;·&nbsp; Free
</p>

<p align="center">or with Homebrew: <code>brew tap adigold/tap && brew trust adigold/tap && brew install --cask ag-plugfinder</code></p>

---

## Why

You know the plugin you want. You can picture its window. But Logic's plugin menu is a long list of names, grouped by maker, three levels deep. AG PlugFinder shows every plugin as a picture you recognise at a glance, finds it as you type, and drops it on your track the moment you press Return.

<p align="center">
  <img src="docs/images/library.png" width="900" alt="The AG PlugFinder library window">
</p>

## Find

- **Every plugin, with a picture.** Your Audio Units and Logic's own plugins, each with a screenshot of its real window. Pictures of 122 of Logic's plugins come built in, so a new install is ready straight away.
- **Search by name or by what it does.** Type "warm tape saturation" or "feedback", not only names. Plugins that stop matching fade away and the rest glide into place.
- **Category buttons.** One click shows only EQs, reverbs, delays and so on. Choose collections, categories or both in Settings.
- **Picture size slider.** Any size from small to extra large.
- **Suggestions for the selected track.** On a track called Vocal, Drums, Bass, Guitar, Keys or Master, the plugins that fit come first.
- **More like this.** The info panel shows similar plugins you already own.
- **Favorites, collections and your own notes** on every plugin, synced to your other Macs through iCloud Drive. Drag a plugin onto a collection to add it.
- **See it large.** Click a plugin's picture to open it big and zoom in.
- **Free descriptions.** On Macs with Apple Intelligence, plugin descriptions come free from the Mac itself, nothing to download. Or use the web lookup with your own key for the most detail.

## Add to Logic

- **Return puts it on the track.** Instruments go into the instrument slot, effects into the first free insert, MIDI effects into the MIDI slot. Legacy Logic plugins too.
- **Always a proper instrument track.** Pick an instrument while an audio track, or a track that already has an instrument, is selected, and a new instrument track is made for it, named after the instrument.
- **Chains.** Save a chain like EQ, Compressor, DeEsser and Reverb, and add the whole chain at once.
- **Number keys.** Pin a plugin or a chain to a number and add it from anywhere in Logic.
- **Insert before or after** another plugin on the track.
- **As a send.** Choose a reverb or delay and it lands on a new aux with the send already set to a sensible level.
- **Several tracks at once.** Tick the tracks, press Add.
- **New track with an instrument.** One step from the instrument's menu.

## Control the selected track

<p align="center">
  <img src="docs/images/track-panel.png" width="340" alt="The track panel: the selected track's plugins with on and off switches">
  &nbsp;&nbsp;
  <img src="docs/images/find-on-tracks.png" width="380" alt="Find on tracks: every track that uses a plugin">
</p>

- **See what is on the track**, in order, with an on and off switch for each plugin.
- **Drag to reorder.** Drag effects in the panel and the order changes in Logic too.
- **Open, replace or remove** any plugin. A replacement goes into the same slot, so your chain order stays.
- **Save the track as a chain**, then add it to any other track later.
- **Remove the last plugin you added**, or clear every effect from the track.
- **Open all of the track's plugins side by side**, and close every plugin window with one key.
- **Find on tracks.** See every track in the project that uses a plugin, and jump to it.

## Your keys

<p align="center">
  <img src="docs/images/shortcuts.png" width="560" alt="Settings: a shortcut for every action">
</p>

Every action has its own shortcut, and you can change all of them in **Settings > Shortcuts**. Hyper key shortcuts (Control, Option, Shift and Command together) never clash with Logic's own key commands, and Caps Lock can become your Hyper key.

| Default | What it does |
|---|---|
| ⌃⌥P | Open AG PlugFinder, press again to go back to Logic |
| ⌃⌥1 to ⌃⌥9 | Add what you pinned to that number |
| ⌃⌥O | Open the track's plugins side by side |
| ⌃⌥W | Close plugin windows |
| Return | Add the selected plugin |
| Arrows | Move through the results |
| Esc | Clear the search |

## Always up to date

<p align="center">
  <img src="docs/images/whats-new.png" width="760" alt="The What's New window">
</p>

Check for Update sits at the top right of the window. A new version downloads with live progress, is checked to be the genuine app, installs, and the app opens again by itself on a What's New page.

## Get started

1. [Download AG PlugFinder](https://github.com/adigold/AG-PlugFinder/releases/latest/download/AG-PlugFinder.dmg), open it and drag the app to Applications. Or install it with [Homebrew](https://brew.sh):

   ```sh
   brew tap adigold/tap
   brew trust adigold/tap
   brew install --cask ag-plugfinder
   ```
2. Open it. A short welcome tour asks for the one permission it needs: to work with Logic's plugin slots (System Settings > Privacy & Security). Nothing else in Logic is touched.
3. It finds your plugins and gets their pictures. Download the free plugin pack from the ⋯ menu to get pictures and descriptions other users already have.
4. In Logic, select a track, press ⌃⌥P, type, press Return.

AG PlugFinder lives in the menu bar and can start when you log in.

## What's new

**0.7.0**
- Free plugin descriptions on Macs with Apple Intelligence: nothing to download, nothing leaves your Mac.
- Click a plugin's picture to see it large, and zoom in.
- Drag a plugin onto a collection to add it there.
- Install with Homebrew.

**0.6.2**
- AG PlugFinder checks for a new version as soon as it opens, and shows what's new with one click to install.
- Choosing an instrument while the track already has one makes a new instrument track for it, named after the instrument.

**0.6.1**
- Drag effects in the track panel to change their order in Logic.
- Share AG PlugFinder on X, WhatsApp, Messages, Instagram, Telegram, Facebook, LinkedIn or by email, with a ready-made picture.

**0.6.0**
- Set your own shortcut for every action, including Hyper key shortcuts, and use Caps Lock as a Hyper key.
- A designed What's New window with everything a new version brings.
- A slider for the picture size.
- Choosing an instrument while an audio track is selected makes a new instrument track for it.
- Category buttons show above your plugins from the start.

**0.5.0**
- Control the selected track: see its plugins, switch them on and off, open, replace or remove them, save the track as a chain, clear its effects.
- Insert before or after another plugin, add as a send, add to several tracks, find every track that uses a plugin, start a new instrument track.
- Open all of a track's plugins side by side, and close plugin windows with one key.
- Chains, number keys, collections, notes, search by what a plugin does, more like this, track suggestions, a plugin report, and sync with your other Macs through iCloud Drive.
- Pictures of Logic's own plugins built in, legacy Logic plugins, and a new update window that installs and reopens the app by itself.
- ⌃⌥P now opens the main window.

See every release on the [Releases page](https://github.com/adigold/AG-PlugFinder/releases).

## Build it yourself

```sh
brew install xcodegen
xcodegen generate
open AGPlugFinder.xcodeproj
```

---

<p align="center">Made by Adi Goldstein for everyone who makes music in Logic Pro.</p>
