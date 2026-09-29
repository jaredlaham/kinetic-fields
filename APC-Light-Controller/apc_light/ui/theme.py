"""Colours and the application stylesheet (dark, hardware-utility look)."""

BG = "#0d0e10"
PANEL = "#141518"
PANEL_2 = "#1a1c20"
RAISED = "#202329"
BORDER = "#262930"
TEXT = "#e8e9eb"
TEXT_DIM = "#8b9099"
TEXT_FAINT = "#5b6068"
ACCENT = "#ffb020"
ACCENT_DIM = "#6b4a10"
GOOD = "#39d98a"
BAD = "#ff4545"
BLACKOUT = "#e5322d"

MONO = '"SF Mono", "Menlo", "Monaco", "DejaVu Sans Mono", monospace'

STYLESHEET = f"""
* {{ outline: none; }}
QWidget {{ color: {TEXT}; font-size: 13px; }}
QMainWindow, QDialog {{ background: {BG}; }}
QMenuBar {{ background: {PANEL}; }}
QMenuBar::item:selected {{ background: {RAISED}; }}
QSplitter::handle {{ background: {BORDER}; }}
QToolTip {{ background: {RAISED}; color: {TEXT}; border: 1px solid {BORDER}; padding: 4px 6px; }}

#Header, #Sidebar, #Inspector, #Diagnostics, #Footer {{ background: {PANEL}; }}
#Header {{ border-bottom: 1px solid {BORDER}; }}
#Footer {{ border-top: 1px solid {BORDER}; }}
#Sidebar {{ border-right: 1px solid {BORDER}; }}
#Inspector {{ border-left: 1px solid {BORDER}; }}
#Diagnostics {{ border-top: 1px solid {BORDER}; }}
#Stage {{ background: {BG}; }}

QLabel {{ background: transparent; }}
QLabel#AppTitle {{ font-size: 13px; font-weight: 700; letter-spacing: 3px; color: {TEXT}; }}
QLabel#AppSub {{ color: {TEXT_FAINT}; font-size: 11px; letter-spacing: 1px; }}
QLabel#Section {{ color: {TEXT_FAINT}; font-size: 10px; font-weight: 700; letter-spacing: 2px; padding: 14px 14px 6px 14px; }}
QLabel#CtlLabel {{ color: {TEXT_DIM}; font-size: 10px; font-weight: 700; letter-spacing: 2px; }}
QLabel#CtlValue {{ color: {ACCENT}; font-family: {MONO}; font-size: 11px; }}
QLabel#NowTitle {{ font-size: 22px; font-weight: 700; letter-spacing: 4px; }}
QLabel#NowSub {{ color: {TEXT_DIM}; font-size: 12px; }}
QLabel#Hint {{ color: {TEXT_FAINT}; font-size: 11px; }}
QLabel#Mono {{ font-family: {MONO}; color: {TEXT_DIM}; font-size: 11px; }}

QPushButton {{
    background: {RAISED}; border: 1px solid {BORDER}; border-radius: 6px;
    padding: 6px 12px; color: {TEXT};
}}
QPushButton:hover {{ border-color: #3a3e46; background: #262a31; }}
QPushButton:pressed {{ background: #1a1d22; }}
QPushButton:checked {{ background: {ACCENT_DIM}; border-color: {ACCENT}; color: #ffe2a8; }}
QPushButton:disabled {{ color: {TEXT_FAINT}; }}
QPushButton#Seg {{ border-radius: 0; padding: 5px 10px; font-size: 12px; }}
QPushButton#SegFirst {{ border-top-right-radius: 0; border-bottom-right-radius: 0; padding: 5px 10px; font-size: 12px; }}
QPushButton#SegLast {{ border-top-left-radius: 0; border-bottom-left-radius: 0; padding: 5px 10px; font-size: 12px; }}
QPushButton#Blackout {{
    background: #3a0d0c; border: 1px solid {BLACKOUT}; color: #ffd6d4;
    font-size: 15px; font-weight: 800; letter-spacing: 4px; border-radius: 8px; padding: 14px;
}}
QPushButton#Blackout:hover {{ background: #551312; }}
QPushButton#Blackout:pressed {{ background: {BLACKOUT}; color: white; }}
QPushButton#Link {{ background: transparent; border: none; color: {TEXT_DIM}; padding: 4px 6px; }}
QPushButton#Link:hover {{ color: {TEXT}; }}

QComboBox {{
    background: {RAISED}; border: 1px solid {BORDER}; border-radius: 6px; padding: 5px 10px; min-height: 18px;
}}
QComboBox:hover {{ border-color: #3a3e46; }}
QComboBox::drop-down {{ border: none; width: 18px; }}
QComboBox QAbstractItemView {{ background: {RAISED}; border: 1px solid {BORDER}; selection-background-color: {ACCENT_DIM}; }}

QLineEdit {{
    background: {PANEL_2}; border: 1px solid {BORDER}; border-radius: 6px; padding: 6px 8px;
    selection-background-color: {ACCENT_DIM};
}}
QLineEdit:focus {{ border-color: {ACCENT}; }}

QSlider::groove:horizontal {{ height: 4px; background: #2a2d33; border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 2px; }}
QSlider::handle:horizontal {{
    background: #f2f2f2; width: 14px; height: 14px; margin: -6px 0; border-radius: 7px; border: 1px solid rgba(0,0,0,0.4);
}}
QSlider::handle:horizontal:hover {{ background: white; }}
QSlider::groove:horizontal:disabled {{ background: #1f2226; }}
QSlider::sub-page:horizontal:disabled {{ background: #3a3e46; }}

QCheckBox {{ spacing: 8px; background: transparent; }}
QCheckBox::indicator {{ width: 30px; height: 16px; border-radius: 8px; background: #2a2d33; border: 1px solid {BORDER}; }}
QCheckBox::indicator:checked {{ background: {ACCENT}; border-color: {ACCENT}; }}

QScrollArea {{ border: none; background: transparent; }}
QScrollArea > QWidget > QWidget {{ background: transparent; }}
QScrollBar:vertical {{ background: transparent; width: 8px; margin: 2px; }}
QScrollBar::handle:vertical {{ background: #2c3036; border-radius: 3px; min-height: 30px; }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}

QPlainTextEdit {{
    background: #0a0b0c; border: 1px solid {BORDER}; border-radius: 6px;
    font-family: {MONO}; font-size: 11px; color: #b9c0c9;
}}
QMenu {{ background: {RAISED}; border: 1px solid {BORDER}; padding: 4px; }}
QMenu::item {{ padding: 5px 18px; border-radius: 4px; }}
QMenu::item:selected {{ background: {ACCENT_DIM}; }}
QMenu::separator {{ height: 1px; background: {BORDER}; margin: 4px 6px; }}

#SceneRow {{ background: transparent; border-radius: 7px; border: 1px solid transparent; }}
#SceneRow:hover {{ background: {PANEL_2}; }}
#SceneRow[active="true"] {{ background: #221b0e; border: 1px solid {ACCENT_DIM}; }}
QLabel#SceneName {{ font-size: 13px; }}
QLabel#SceneName[active="true"] {{ color: {ACCENT}; font-weight: 600; }}
QLabel#Badge {{
    color: {TEXT_DIM}; background: {RAISED}; border: 1px solid {BORDER}; border-radius: 4px;
    font-family: {MONO}; font-size: 10px; padding: 0 5px; min-width: 8px;
}}
QToolButton#Star {{ background: transparent; border: none; color: {TEXT_FAINT}; font-size: 15px; padding: 0 2px; }}
QToolButton#Star:hover {{ color: {TEXT}; }}
QToolButton#Star:checked {{ color: {ACCENT}; }}

QToolButton#Swatch {{ border: 1px solid rgba(0,0,0,0.5); border-radius: 5px; }}
QToolButton#Swatch:hover {{ border: 1px solid white; }}
"""
