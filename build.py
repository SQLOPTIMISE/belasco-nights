"""Packs the mod folders into belasco_nights.zip, ready for the BeamNG mods folder."""
import os
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
MOD_DIRS = ("belascoNights", "lua", "scripts")
OUT = os.path.join(ROOT, "belasco_nights.zip")

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as archive:
    for mod_dir in MOD_DIRS:
        for folder, _, files in os.walk(os.path.join(ROOT, mod_dir)):
            for name in sorted(files):
                path = os.path.join(folder, name)
                archive.write(path, os.path.relpath(path, ROOT).replace(os.sep, "/"))

print("wrote", OUT)
