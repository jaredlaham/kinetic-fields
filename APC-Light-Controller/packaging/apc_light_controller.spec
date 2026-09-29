# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for "APC Light Controller.app" (onedir, windowed).
# Build with ./build_app.sh rather than calling this directly.

import os
import sys

from PyInstaller.utils.hooks import collect_submodules

ROOT = os.path.abspath(os.path.join(SPECPATH, ".."))
sys.path.insert(0, ROOT)
from apc_light import APP_NAME, BUNDLE_ID, __version__  # noqa: E402

ICON = os.environ.get("APC_ICON") or None
TARGET_ARCH = os.environ.get("TARGET_ARCH") or None  # arm64 / x86_64 / universal2; default = this Mac

hiddenimports = collect_submodules("apc_light.effects") + ["rtmidi", "rtmidi._rtmidi"]

a = Analysis(
    [os.path.join(ROOT, "main.py")],
    pathex=[ROOT],
    binaries=[],
    datas=[(os.path.join(ROOT, "apc_light", "assets"), "apc_light/assets")],
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter", "PySide6.QtNetwork", "PySide6.QtQml", "PySide6.QtQuick", "PySide6.QtPdf",
              "PySide6.QtWebEngineCore", "PySide6.QtMultimedia", "PySide6.Qt3DCore"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name=APP_NAME,
    debug=False,
    strip=False,
    upx=False,
    console=False,          # no Terminal window
    argv_emulation=False,
    target_arch=TARGET_ARCH,
    codesign_identity=None,  # ad-hoc signed by PyInstaller / build_app.sh
    entitlements_file=None,
)

coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name=APP_NAME)

app = BUNDLE(
    coll,
    name=f"{APP_NAME}.app",
    icon=ICON,
    bundle_identifier=BUNDLE_ID,
    version=__version__,
    info_plist={
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundleShortVersionString": __version__,
        "CFBundleVersion": __version__,
        "LSApplicationCategoryType": "public.app-category.music",
        "LSMinimumSystemVersion": "11.0",
        "NSHighResolutionCapable": True,
        "NSRequiresAquaSystemAppearance": False,
        "NSHumanReadableCopyright": "© Jared Laham / Kinetic Fields",
    },
)
