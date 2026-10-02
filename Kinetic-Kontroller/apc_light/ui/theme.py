"""Application stylesheet, generated from the design tokens in design.py.

Custom-painted components (components.py, apc_view.py, browser rows) read the
tokens directly; this stylesheet covers the standard Qt widgets so that none
of them falls back to a default look.
"""

from .design import C, F, H, R

# Kept for code that imports these names.
BG, PANEL, BORDER, TEXT, TEXT_DIM, ACCENT, GOOD = (C.WORKSPACE, C.INSPECTOR, C.BORDER, C.TEXT, C.TEXT_2,
                                                    C.VALUE, C.GOOD)

MONO = '"SF Mono", "Menlo", "Monaco", "DejaVu Sans Mono", monospace'

STYLESHEET = f"""
* {{ outline: none; }}
QWidget {{ color: {C.TEXT}; font-size: {F.LABEL}px; }}
QMainWindow, QDialog {{ background: {C.WORKSPACE}; }}
QToolTip {{ background: {C.CONTROL}; color: {C.TEXT}; border: 1px solid {C.BORDER_STRONG}; padding: 3px 6px;
            font-size: {F.SMALL}px; }}

/* ---- zones -------------------------------------------------------------- */
#Toolbar {{ background: {C.CHROME}; border-bottom: 1px solid {C.CHROME_EDGE}; }}
#StatusBar {{ background: {C.CHROME}; border-top: 1px solid {C.CHROME_EDGE}; }}
#Browser {{ background: {C.BROWSER}; }}
#BrowserTop {{ background: {C.BROWSER}; border-bottom: 1px solid {C.SEPARATOR}; }}
#Workspace {{ background: {C.WORKSPACE}; }}
#WorkspaceBar {{ background: {C.WORKSPACE_BAR}; border-bottom: 1px solid {C.SEPARATOR}; }}
#Inspector {{ background: {C.INSPECTOR}; }}
#InspectorTop {{ background: {C.INSPECTOR}; border-bottom: 1px solid {C.SEPARATOR}; }}
#InspectorFoot {{ background: {C.INSPECTOR}; border-top: 1px solid {C.SEPARATOR}; }}
QSplitter::handle {{ background: {C.SEPARATOR}; }}

/* ---- text roles ----------------------------------------------------------- */
QLabel {{ background: transparent; }}
QLabel#AppTitle {{ font-size: {F.TITLE}px; font-weight: 500; color: {C.TEXT}; }}
QLabel#AppSub {{ font-size: {F.SUBTITLE}px; color: {C.TEXT_2}; }}
QLabel#Param {{ font-size: {F.LABEL}px; color: {C.TEXT}; }}
QLabel#Value {{ font-size: {F.VALUE}px; font-weight: 500; color: {C.VALUE}; }}
QLabel#Caption {{ font-size: {F.SMALL}px; color: {C.TEXT_3}; }}
QLabel#Hint {{ font-size: {F.SMALL}px; color: {C.TEXT_3}; }}
QLabel#Status {{ font-size: {F.STATUS}px; color: {C.TEXT_2}; }}
QLabel#Telemetry {{ font-size: {F.STATUS}px; color: {C.TEXT_3}; }}
QLabel#Mono {{ font-family: {MONO}; font-size: {F.SMALL}px; color: {C.TEXT_2}; }}
QLabel#MeterLabel {{ font-size: {F.BADGE}px; font-weight: 500; color: {C.TEXT_2}; }}
QLabel#EffectName {{ font-size: {F.ROW}px; color: {C.TEXT}; }}

/* ---- text buttons ----------------------------------------------------------- */
QPushButton {{
    background: {C.CONTROL}; color: {C.TEXT}; border: 1px solid {C.BORDER_STRONG};
    border-radius: {R.CONTROL}px; padding: 0 10px; min-height: {H.BUTTON - 2}px; font-size: {F.LABEL}px;
}}
QPushButton:hover {{ background: {C.CONTROL_HOVER}; }}
QPushButton:pressed {{ background: {C.CONTROL_PRESSED}; }}
QPushButton:checked {{ background: {C.SELECT}; border-color: {C.SELECT}; color: white; }}
QPushButton:disabled {{ color: {C.TEXT_DISABLED}; background: {C.FIELD}; }}
QPushButton:focus {{ border: 1px solid {C.FOCUS}; }}
QPushButton#Blackout {{
    background: {C.CONTROL}; border: 1px solid {C.CONTROL_BORDER}; color: {C.TEXT};
    font-size: 13px; font-weight: 600; letter-spacing: 1px; min-height: 34px;
}}
QPushButton#Blackout:hover {{ background: {C.CONTROL_HOVER}; }}
QPushButton#Blackout:pressed {{ background: {C.CONTROL_PRESSED}; padding-top: 1px; }}
QPushButton#Preset {{ font-size: {F.SMALL}px; padding: 0 4px; min-height: 22px; }}

/* ---- fields ------------------------------------------------------------------ */
QLineEdit, QPlainTextEdit {{
    background: {C.FIELD}; border: 1px solid {C.BORDER}; border-radius: {R.CONTROL}px;
    padding: 2px 6px; selection-background-color: {C.SELECT}; font-size: {F.LABEL}px;
}}
QLineEdit {{ min-height: {H.SEARCH - 6}px; }}
QLineEdit:focus, QPlainTextEdit:focus {{ border: 1px solid {C.FOCUS}; }}
QLineEdit#Search {{ background: {C.BROWSER_HEADER}; border: 1px solid {C.BORDER}; padding-left: 24px; }}
QPlainTextEdit#Log {{ font-family: {MONO}; font-size: 10px; color: #B7BEC6; background: #17191B; }}
QPlainTextEdit#Notes {{ background: {C.BROWSER_HEADER}; border: none; border-radius: 0; padding: 8px; }}

QComboBox {{
    background: {C.CONTROL}; border: 1px solid {C.BORDER_STRONG}; border-radius: {R.CONTROL}px;
    padding: 0 8px; min-height: {H.CONTROL - 2}px; font-size: {F.LABEL}px;
}}
QComboBox:hover {{ background: {C.CONTROL_HOVER}; }}
QComboBox:focus {{ border: 1px solid {C.FOCUS}; }}
QComboBox::drop-down {{ border: none; width: 18px; }}
QComboBox::down-arrow {{ image: none; width: 0; height: 0; }}
QComboBox QAbstractItemView {{
    background: {C.CONTROL}; border: 1px solid {C.BORDER_STRONG}; padding: 2px;
    selection-background-color: {C.SELECT}; outline: none;
}}

/* ---- sliders: thin track, small thumb --------------------------------------- */
QSlider {{ min-height: 16px; background: transparent; border: none; }}
QSlider::groove:horizontal {{ height: 3px; background: #1E2124; border-radius: 1px; }}
QSlider::sub-page:horizontal {{ background: {C.SELECT}; border-radius: 1px; }}
QSlider::handle:horizontal {{
    background: #E4E6E9; width: 14px; height: 14px; margin: -6px 0; border-radius: 7px;
    border: 1px solid #1B1D20;
}}
QSlider::handle:horizontal:hover {{ background: #FFFFFF; }}
QSlider::handle:horizontal:pressed {{ background: #D2D5D9; }}
QSlider::sub-page:horizontal:disabled {{ background: {C.CONTROL_BORDER}; }}

/* ---- scroll bars: slim overlay style ----------------------------------------- */
QScrollArea {{ border: none; background: transparent; }}
QScrollArea > QWidget > QWidget {{ background: transparent; }}
QScrollBar:vertical {{ background: transparent; width: 8px; margin: 0; }}
QScrollBar::handle:vertical {{ background: rgba(255,255,255,40); border-radius: 3px; min-height: 28px; margin: 1px; }}
QScrollBar::handle:vertical:hover {{ background: rgba(255,255,255,70); }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}
QScrollBar:horizontal {{ height: 0; }}

/* ---- menus ------------------------------------------------------------------- */
QMenu {{ background: {C.CONTROL}; border: 1px solid {C.BORDER_STRONG}; padding: 4px; font-size: {F.LABEL}px; }}
QMenu::item {{ padding: 4px 18px 4px 12px; border-radius: 3px; }}
QMenu::item:selected {{ background: {C.SELECT}; color: white; }}
QMenu::item:disabled {{ color: {C.TEXT_DISABLED}; }}
QMenu::separator {{ height: 1px; background: {C.BORDER_STRONG}; margin: 4px 6px; }}
QMenuBar {{ background: {C.CHROME}; font-size: {F.LABEL}px; }}
QMenuBar::item:selected {{ background: {C.CONTROL_HOVER}; }}

QMessageBox {{ background: {C.INSPECTOR}; }}
"""
