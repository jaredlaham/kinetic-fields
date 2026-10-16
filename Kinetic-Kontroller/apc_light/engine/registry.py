"""Automatic effect discovery.

Every module in the ``apc_light.effects`` package is imported and every
:class:`Effect` subclass defined in it is registered. Extra effects can also be
dropped as ``.py`` files into the user effects folder (see
``settings.paths.user_effects_dir``) without rebuilding the app.

A broken effect module is logged and skipped; it never stops the app.
"""

from __future__ import annotations

import importlib
import importlib.util
import inspect
import logging
import pkgutil
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Type

from .effect import CATEGORIES, Effect

log = logging.getLogger("apc.registry")


class EffectRegistry:
    def __init__(self) -> None:
        self._effects: Dict[str, Type[Effect]] = {}

    # ------------------------------------------------------------------
    def discover(self, package: str = "apc_light.effects", extra_dirs: Iterable[Path] = ()) -> "EffectRegistry":
        pkg = importlib.import_module(package)
        for info in sorted(pkgutil.iter_modules(pkg.__path__), key=lambda i: i.name):
            if info.name.startswith("_"):
                continue
            name = f"{package}.{info.name}"
            try:
                self._register_module(importlib.import_module(name))
            except Exception:
                log.exception("Could not load effect module %s", name)
        for folder in extra_dirs:
            self._load_folder(Path(folder))
        log.info("Loaded %d effects: %s", len(self._effects), ", ".join(self._effects))
        return self

    def _load_folder(self, folder: Path) -> None:
        if not folder.is_dir():
            return
        for path in sorted(folder.glob("*.py")):
            if path.name.startswith("_"):
                continue
            mod_name = f"apc_user_effects.{path.stem}"
            try:
                spec = importlib.util.spec_from_file_location(mod_name, path)
                assert spec and spec.loader
                module = importlib.util.module_from_spec(spec)
                sys.modules[mod_name] = module
                spec.loader.exec_module(module)
                self._register_module(module, user=True)
                log.info("Loaded user effect file %s", path)
            except Exception:
                log.exception("Could not load user effect %s", path)

    def _register_module(self, module, user: bool = False) -> None:
        short = module.__name__.rsplit(".", 1)[-1]
        classes = [
            obj for _, obj in inspect.getmembers(module, inspect.isclass)
            if issubclass(obj, Effect) and obj is not Effect and obj.__module__ == module.__name__
            and not inspect.isabstract(obj) and not getattr(obj, "abstract", False)
        ]
        for cls in classes:
            self.register(cls, default_id=short if len(classes) == 1 else f"{short}.{cls.__name__.lower()}")

    def register(self, cls: Type[Effect], default_id: Optional[str] = None) -> None:
        if not cls.__dict__.get("id"):
            cls.id = default_id or cls.__name__.lower()
        if cls.category not in CATEGORIES:
            log.warning("Effect %s has unknown category %r; using 'Animated'", cls.id, cls.category)
            cls.category = "Animated"
        if cls.id in self._effects and self._effects[cls.id] is not cls:
            log.warning("Effect id %r registered twice; replacing %s with %s", cls.id, self._effects[cls.id], cls)
        self._effects[cls.id] = cls

    # ------------------------------------------------------------------
    def get(self, effect_id: str) -> Optional[Type[Effect]]:
        return self._effects.get(effect_id)

    def ids(self) -> List[str]:
        return [c.id for c in self.all()]

    def all(self) -> List[Type[Effect]]:
        cat = {c: i for i, c in enumerate(CATEGORIES)}
        return sorted(self._effects.values(), key=lambda c: (cat.get(c.category, 9), c.order, c.name))

    def __contains__(self, effect_id: str) -> bool:
        return effect_id in self._effects

    def __len__(self) -> int:
        return len(self._effects)
