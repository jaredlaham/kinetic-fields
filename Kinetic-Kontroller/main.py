"""Entry point: ``python main.py`` (development) and the PyInstaller bundle."""

import sys

from apc_light.app.application import main

if __name__ == "__main__":
    sys.exit(main())
