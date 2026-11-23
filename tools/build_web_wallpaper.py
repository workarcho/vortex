"""Builds the autobattle demo as a LOCAL Wallpaper Engine web wallpaper (Godot web export + the player's data).

    python tools/build_web_wallpaper.py [--godot PATH] [--out DIR]

1. exports the "Web" preset of godot/ (custom feature `wallpaper`: starts straight in the muted autobattle demo,
   project.godot overrides; custom HTML shell godot/web/wallpaper_shell.html with the file:// fetch shim);
2. packs ../ftl-data into ftl-data.pck (files under res://ftl-data/, mounted by FtlData on the web), leaving out what
   the muted English wallpaper never reads (audio, CJK fonts, iPad art);
3. writes the pack size into index.html (progress bar) and a Wallpaper Engine project.json.

The output holds the player's own FTL data: it stays under build/ (gitignored) and is never published.
Requires the Godot 4.7 web export templates.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(REPO, "godot")
DATA = os.path.join(REPO, "ftl-data")
DEFAULT_OUT = os.path.join(REPO, "build", "wallpaper", "Vortex Autobattle Web")
PACKER_PROJECT = os.path.join(REPO, "build", "web-packer")
SKIP = ["audio", "fonts/ja", "fonts/zh-Hans", "img/ipad"]
TITLE = "Vortex Autobattle"


def run(cmd, timeout):
    print("+", " ".join(f'"{c}"' if " " in c else c for c in cmd), flush=True)
    r = subprocess.run(cmd, timeout=timeout)
    if r.returncode != 0:
        sys.exit(f"failed ({r.returncode})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=shutil.which("godot.console") or shutil.which("godot") or "godot")
    ap.add_argument("--out", default=DEFAULT_OUT)
    a = ap.parse_args()
    if not os.path.isfile(os.path.join(DATA, "data", "blueprints.xml")):
        sys.exit(f"no ftl-data at {DATA}")
    os.makedirs(a.out, exist_ok=True)
    index = os.path.join(a.out, "index.html")

    run([a.godot, "--headless", "--path", PROJECT, "--export-release", "Web", index], timeout=900)

    # The packer runs in an empty throwaway project (no autoloads, nothing imported).
    os.makedirs(PACKER_PROJECT, exist_ok=True)
    with open(os.path.join(PACKER_PROJECT, "project.godot"), "w", newline="\n") as f:
        f.write('config_version=5\n\n[application]\n\nconfig/name="ftl-data packer"\n')
    pck = os.path.join(a.out, "ftl-data.pck")
    run([a.godot, "--headless", "--path", PACKER_PROJECT, "-s", os.path.join(REPO, "tools", "pack_ftl_data.gd"),
         "--", DATA, pck] + SKIP, timeout=900)

    with open(index, encoding="utf-8") as f:
        html = f.read()
    if "__FTL_DATA_PACK_SIZE__" not in html:
        sys.exit("index.html: no __FTL_DATA_PACK_SIZE__ placeholder (custom shell not used?)")
    with open(index, "w", encoding="utf-8", newline="") as f:
        f.write(html.replace("__FTL_DATA_PACK_SIZE__", str(os.path.getsize(pck))))

    project = {
        "contentrating": "Everyone",
        "description": "Two AI ships fight each other forever (FTL Proto autobattle demo, local build).",
        "file": "index.html",
        "title": TITLE,
        "type": "web",
        "visibility": "private",
    }
    if os.path.isfile(os.path.join(a.out, "preview.jpg")):
        project["preview"] = "preview.jpg"
    with open(os.path.join(a.out, "project.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(project, f, indent=4)
        f.write("\n")

    total = sum(os.path.getsize(os.path.join(a.out, n)) for n in os.listdir(a.out))
    print(f"wallpaper: {a.out} ({total / 1048576:.1f} MB)")


if __name__ == "__main__":
    main()
