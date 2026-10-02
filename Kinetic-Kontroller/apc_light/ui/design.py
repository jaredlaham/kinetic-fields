"""Design tokens: the single source of truth for the UI's look.

Every widget and the stylesheet (theme.py) read from here. The structure is
several graphite elevations rather than one dark surface:

    toolbar / status bar   medium graphite   (CHROME)
    browser                medium grey       (BROWSER)  <- lightest panel
    workspace              near-black        (WORKSPACE) <- the canvas
    inspector              dark graphite     (INSPECTOR)

Saturated colour is reserved for LEDs, thumbnails, selection, MIDI activity,
connection state and parameter values.
"""

from __future__ import annotations

from PySide6.QtGui import QColor


class C:
    # surfaces
    CHROME = "#383B3F"
    CHROME_EDGE = "#2A2C2F"
    BROWSER = "#3F4246"
    BROWSER_HEADER = "#373A3E"
    ROW_HOVER = "#484C51"
    WORKSPACE = "#1B1E21"
    WORKSPACE_BAR = "#23262A"
    INSPECTOR = "#2B2E32"
    SECTION = "#33373B"
    FIELD = "#24272A"
    CONTROL = "#3E4247"
    CONTROL_HOVER = "#484D53"
    CONTROL_PRESSED = "#2E3135"
    CONTROL_BORDER = "#55595F"
    BADGE = "#2C2F33"
    # lines
    BORDER = "rgba(255, 255, 255, 20)"        # ~0.08
    BORDER_STRONG = "rgba(255, 255, 255, 36)"  # ~0.14
    SEPARATOR = "#26292C"
    # text
    TEXT = "#E8EAEC"
    TEXT_2 = "#A4A8AD"
    TEXT_3 = "#767C82"
    TEXT_DISABLED = "#5E6368"
    # accents
    SELECT = "#2F6BD6"
    SELECT_HOVER = "#3A77E0"
    SELECT_DIM = "#2A4F8F"
    FOCUS = "#5B9BFF"
    GOOD = "#3CC261"
    PLAY = "#3DD162"
    VALUE = "#F2B441"
    STAR = "#F5A524"
    METER = "#43C567"
    METER_HOT = "#E9C046"
    BAD = "#E0534A"

    @staticmethod
    def q(value: str) -> QColor:
        if value.startswith("rgba"):
            r, g, b, a = [int(float(x)) for x in value[5:-1].split(",")]
            return QColor(r, g, b, a)
        return QColor(value)


class F:
    """Font sizes in px (system font: SF Pro on macOS)."""
    TITLE = 15
    SUBTITLE = 11
    TOOLBAR = 12
    ROW = 13
    LABEL = 12
    SECTION = 11
    SMALL = 11
    STATUS = 11
    VALUE = 12
    BADGE = 10


class S:
    """Spacing scale."""
    XXS = 2
    XS = 4
    SM = 6
    MD = 8
    LG = 12
    XL = 16
    XXL = 24


class R:
    """Corner radii. Panels are square (0)."""
    CONTROL = 4
    SMALL = 3
    SWATCH = 3
    PAD = 5


class H:
    """Fixed heights / widths."""
    TOOLBAR = 56
    WORKSPACE_BAR = 42
    TABS = 30
    ROW = 34
    THUMB = 24
    SECTION = 28
    CONTROL = 26
    BUTTON = 28
    ICON_BUTTON = 28
    STATUS = 26
    SEARCH = 26
    SWATCH = 24
    BROWSER_MIN = 280
    BROWSER = 310
    BROWSER_MAX = 380
    INSPECTOR_MIN = 360
    INSPECTOR = 392
    INSPECTOR_MAX = 460
