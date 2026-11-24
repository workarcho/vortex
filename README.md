# Vortex

A fan-made, clean-room reimplementation of **FTL: Faster Than Light** (1.6.9, Advanced Edition) in Godot 4,
with a touch interface designed for phones and foldables, and a PC version that scales to any resolution.

> Not affiliated with or endorsed by Subset Games. **You need your own copy of FTL.** This project contains no
> FTL code, images, sounds or text: on first launch it asks for the `ftl.dat` file from your installation and
> reads the game data from it.

## Why

FTL's interface is drawn at a fixed 1280×720 and scaled as one image, which is tiny on a phone. This project
rebuilds the game so the interface can be laid out for each screen: a compact layout for phones, a split or
panning layout for unfolded foldables, and crisp text on any PC resolution.

## Playing

1. Download the APK (Android) or the Windows zip from [Releases](../../releases).
2. Find `ftl.dat` in your FTL installation (Steam: `steamapps/common/FTL Faster Than Light/ftl.dat`).
   On Android, copy it to the phone first.
3. Start the game and select `ftl.dat` when asked. It is unpacked once (about 280 MB) into the app's data folder.

Android 8+ is required. The Windows version needs no installation: unzip and run.

### Touch controls

- **Tap** acts as a click. Aiming a weapon or moving crew pauses the game until you pick a target (PAUSE / CANCEL).
- **+ / −** button: switches between adding and removing power when tapping systems and weapons.
- **Hold one finger and tap with another** to remove power, or **hold and drag** to select several crew.
- Holding a finger on anything shows its tooltip.
- Options → *Phone / Unfolded Screen Layout* switches between the available layouts.

## Live wallpaper (Wallpaper Engine)

The PC version can turn its autobattle demo (two AI ships fighting forever, muted) into a web wallpaper for
[Wallpaper Engine](https://www.wallpaperengine.io):

1. In the main menu, click **CREATE HTML WALLPAPER** (bottom left). The first time it builds the wallpaper from
   the `web-wallpaper/` folder shipped next to the game and your FTL data (a few seconds), then opens its folder:
   `%APPDATA%\Godot\app_userdata\FTL Proto\wallpaper\Vortex Autobattle\`. Later clicks just open the folder (it is
   rebuilt after a game update).
2. In Wallpaper Engine: **Create Wallpaper** → choose `index.html` in that folder.
3. The wallpaper's settings have margin sliders to keep the battle clear of desktop icons and the taskbar, and an
   **Interface** choice: *Full UI*, *Hull only* (each ship's hull bar and name) or *None* (just the ships). The
   frame rate follows Wallpaper Engine's FPS limit. The desktop demo takes the same choice as
   `--autobattle-ui=full|hull|none` (or `ftl/autobattle/ui` in `override.cfg`).

The folder contains your FTL data: keep it to yourself (no Workshop upload). Developers: `python
tools/build_web_wallpaper.py` makes the data-less template (`build/web-wallpaper-template/`, used by the button
when running from the editor) and a ready wallpaper under `build/wallpaper/`; `--release` also assembles
`build/release/Vortex-windows.zip` (exe + pck + `web-wallpaper/`).

## Status

Most of the game is playable from the hangar to the Rebel Flagship: combat, crew, systems, events, stores,
sector map, hazards, achievements, unlocks, three profiles and mid-fight saves. Some things are still missing
(tutorial, a few touch-specific menus). Expect bugs; reports are welcome in [Issues](../../issues).

An optional quality-of-life mod (off by default) adds things like weapon cooldown numbers and extended statistics.

## Building

Requires [Godot 4.7](https://godotengine.org) with its export templates.

```
godot --path godot                     # run (PC)
godot --path godot -- --device=phone   # preview the phone layout on PC
bash tools/run_tests.sh                # test suites
```

During development the game data can also be placed in a `ftl-data/` folder next to `godot/`.

## License

[GPL-3.0](LICENSE). FTL: Faster Than Light is © Subset Games; its data is not part of this repository.
