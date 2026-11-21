@echo off
rem Regenerates the PC game package (build\windows\FTL Proto.pck) after code changes.
rem The exe next to it (a copy of godot.exe) never changes.
cd /d "%~dp0..\godot"
godot --headless --path . --export-pack "Windows Desktop" "..\build\windows\FTL Proto.pck"
