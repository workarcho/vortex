"""Builds the autobattle demo as a LOCAL Wallpaper Engine web wallpaper (Godot web export + the player's data).

    python tools/build_web_wallpaper.py [--godot PATH] [--out DIR] [--template-out DIR] [--template-only]
                                        [--release]

1. exports the "Web" preset of godot/ (custom feature `wallpaper`: starts straight in the muted autobattle demo,
   project.godot overrides; custom HTML shell godot/web/wallpaper_shell.html with the file:// fetch shim) into the
   data-less TEMPLATE folder (default build/web-wallpaper-template/): index.html keeps the __FTL_DATA_PACK_SIZE__
   placeholder, plus a Wallpaper Engine project.json and a version stamp (wallpaper-version.txt). The PC game's
   main-menu button "CREATE HTML WALLPAPER" (godot/scripts/autobattle/wallpaper_maker.gd) builds the wallpaper
   from this template and the player's data at runtime; the stamp tells it when a wallpaper made earlier is stale;
2. (unless --template-only) makes the wallpaper itself in --out (default build/wallpaper/Vortex Autobattle Web/):
   the template plus ../ftl-data packed into ftl-data.pck (files under res://ftl-data/, mounted by FtlData on the
   web), leaving out what the muted English wallpaper never reads (audio, CJK fonts, iPad art), with the pack size
   written into index.html (progress bar);
3. --release: also exports the "Windows Desktop" preset as build/release/Vortex/Vortex.exe (+ Vortex.pck), copies
   the template next to it as build/release/Vortex/web-wallpaper/ and zips the folder as
   build/release/Vortex-windows.zip (entries under Vortex/). The template holds no FTL data, so the zip can be
   published; --release alone (with --template-only) does not need ftl-data.

The wallpaper (--out) holds the player's own FTL data: it stays under build/ (gitignored) and is never published.
Requires the Godot 4.7 web (and, for --release, Windows) export templates.
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(REPO, "godot")
DATA = os.path.join(REPO, "ftl-data")
DEFAULT_OUT = os.path.join(REPO, "build", "wallpaper", "Vortex Autobattle Web")
DEFAULT_TEMPLATE = os.path.join(REPO, "build", "web-wallpaper-template")
RELEASE_DIR = os.path.join(REPO, "build", "release", "Vortex")
RELEASE_ZIP = os.path.join(REPO, "build", "release", "Vortex-windows.zip")
PACKER_PROJECT = os.path.join(REPO, "build", "web-packer")
SKIP = ["audio", "fonts/ja", "fonts/zh-Hans", "img/ipad"]  # same list as WallpaperMaker.SKIP
TITLE = "Vortex Autobattle"
PLACEHOLDER = "__FTL_DATA_PACK_SIZE__"
STAMP = "wallpaper-version.txt"  # WallpaperMaker.STAMP


def run(cmd, timeout):
    print("+", " ".join(f'"{c}"' if " " in c else c for c in cmd), flush=True)
    r = subprocess.run(cmd, timeout=timeout)
    if r.returncode != 0:
        sys.exit(f"failed ({r.returncode})")


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_rev():
    try:
        rev = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                             timeout=30).stdout.strip()
        dirty = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--untracked-files=no"],
                               capture_output=True, text=True, timeout=30).stdout.strip()
        return rev + ("-dirty" if dirty else "") if rev else "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def project_json():
    return {
        "contentrating": "Everyone",
        "description": "Two AI ships fight each other forever (FTL Proto autobattle demo, local build).",
        "file": "index.html",
        "title": TITLE,
        "type": "web",
        "visibility": "private",
        # User properties (sliders / combo in Wallpaper Engine's panel), read by the shell's
        # wallpaperPropertyListener and passed to the game as window.vortexMargins (autobattle.gd safe_margins) and
        # window.vortexUi (autobattle.gd set_ui_mode: full / hull / none).
        "general": {"properties": {
            "marginleft": {"order": 0, "text": "Left margin (px)", "type": "slider", "min": 0, "max": 1000,
                           "value": 250, "fraction": False},
            "marginright": {"order": 1, "text": "Right margin (px)", "type": "slider", "min": 0, "max": 1000,
                            "value": 120, "fraction": False},
            "margintop": {"order": 2, "text": "Top margin (px)", "type": "slider", "min": 0, "max": 600,
                          "value": 0, "fraction": False},
            "marginbottom": {"order": 3, "text": "Bottom margin (px)", "type": "slider", "min": 0, "max": 600,
                             "value": 0, "fraction": False},
            "uimode": {"order": 4, "text": "Interface", "type": "combo", "value": "full", "options": [
                {"label": "Full UI", "value": "full"},
                {"label": "Hull only", "value": "hull"},
                {"label": "None", "value": "none"},
            ]},
        }},
    }


def build_template(godot, out):
    """Web export + project.json + stamp, no FTL data (index.html keeps the placeholder)."""
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    index = os.path.join(out, "index.html")
    run([godot, "--headless", "--path", PROJECT, "--export-release", "Web", index], timeout=900)
    with open(index, encoding="utf-8") as f:
        if PLACEHOLDER not in f.read():
            sys.exit(f"index.html: no {PLACEHOLDER} placeholder (custom shell not used?)")
    with open(os.path.join(out, "project.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(project_json(), f, indent=4)
        f.write("\n")
    stamp = [
        "Vortex web wallpaper template",
        "built " + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "git " + git_rev(),
        "index.pck sha1 " + sha1(os.path.join(out, "index.pck")),
        "index.wasm sha1 " + sha1(os.path.join(out, "index.wasm")),
        "index.html sha1 " + sha1(index),
    ]
    with open(os.path.join(out, STAMP), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(stamp) + "\n")
    print(f"template: {out}")


def build_wallpaper(godot, template, out):
    """The template + the player's data pack (what the game's button does at runtime)."""
    if not os.path.isfile(os.path.join(DATA, "data", "blueprints.xml")):
        sys.exit(f"no ftl-data at {DATA}")
    os.makedirs(out, exist_ok=True)
    for name in os.listdir(template):
        if name not in ("index.html", STAMP):
            shutil.copy2(os.path.join(template, name), os.path.join(out, name))

    # The packer runs in an empty throwaway project (no autoloads, nothing imported).
    os.makedirs(PACKER_PROJECT, exist_ok=True)
    with open(os.path.join(PACKER_PROJECT, "project.godot"), "w", newline="\n") as f:
        f.write('config_version=5\n\n[application]\n\nconfig/name="ftl-data packer"\n')
    pck = os.path.join(out, "ftl-data.pck")
    run([godot, "--headless", "--path", PACKER_PROJECT, "-s", os.path.join(REPO, "tools", "pack_ftl_data.gd"),
         "--", DATA, pck] + SKIP, timeout=900)

    with open(os.path.join(template, "index.html"), encoding="utf-8") as f:
        html = f.read()
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8", newline="") as f:
        f.write(html.replace(PLACEHOLDER, str(os.path.getsize(pck))))
    shutil.copy2(os.path.join(template, STAMP), os.path.join(out, STAMP))
    total = sum(os.path.getsize(os.path.join(out, n)) for n in os.listdir(out))
    print(f"wallpaper: {out} ({total / 1048576:.1f} MB)")


def build_release(godot, template):
    """Windows release folder (exe + pck + web-wallpaper/ template) and its zip."""
    if os.path.isdir(RELEASE_DIR):
        shutil.rmtree(RELEASE_DIR)
    os.makedirs(RELEASE_DIR)
    run([godot, "--headless", "--path", PROJECT, "--export-release", "Windows Desktop",
         os.path.join(RELEASE_DIR, "Vortex.exe")], timeout=900)
    shutil.copytree(template, os.path.join(RELEASE_DIR, "web-wallpaper"))
    if os.path.exists(RELEASE_ZIP):
        os.remove(RELEASE_ZIP)
    base = os.path.dirname(RELEASE_DIR)
    with zipfile.ZipFile(RELEASE_ZIP, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _dirs, files in os.walk(RELEASE_DIR):
            for name in sorted(files):
                path = os.path.join(dirpath, name)
                z.write(path, os.path.relpath(path, base).replace(os.sep, "/"))
    print(f"release: {RELEASE_ZIP} ({os.path.getsize(RELEASE_ZIP) / 1048576:.1f} MB)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=shutil.which("godot.console") or shutil.which("godot") or "godot")
    ap.add_argument("--out", default=DEFAULT_OUT, help="the wallpaper with the player's data")
    ap.add_argument("--template-out", default=DEFAULT_TEMPLATE, help="the data-less template")
    ap.add_argument("--template-only", action="store_true", help="no wallpaper (needs no ftl-data)")
    ap.add_argument("--release", action="store_true", help="also the Windows release folder + zip")
    a = ap.parse_args()
    build_template(a.godot, a.template_out)
    if not a.template_only:
        build_wallpaper(a.godot, a.template_out, a.out)
    if a.release:
        build_release(a.godot, a.template_out)


if __name__ == "__main__":
    main()
