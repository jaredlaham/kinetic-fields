import json

from apc_light.settings.store import Settings


def test_roundtrip_and_validation(tmp_path):
    path = tmp_path / "s.json"
    s = Settings(path)
    assert s["speed"] == 50 and s["restore_on_launch"] is False
    s["speed"] = 80
    s["favorites"] = ["heart"]
    s["effect_params"] = {"heart": {"color": "#00ff00"}}
    s.save()
    s2 = Settings(path)
    assert s2["speed"] == 80 and s2["favorites"] == ["heart"]
    assert s2["effect_params"]["heart"]["color"] == "#00ff00"


def test_corrupt_file_falls_back(tmp_path):
    path = tmp_path / "s.json"
    path.write_text("{nope")
    s = Settings(path)
    assert s["speed"] == 50
    assert (tmp_path / "s.corrupt.json").exists()


def test_wrong_types_ignored(tmp_path):
    path = tmp_path / "s.json"
    path.write_text(json.dumps({"speed": "fast", "favorites": "x", "output_mode": "laser", "brightness": 500}))
    s = Settings(path)
    assert s["speed"] == 50 and s["favorites"] != "x" and s["output_mode"] == "palette"
    assert s["brightness"] == 100


def test_v1_settings_put_kinetic_sweep_first(tmp_path):
    path = tmp_path / "s.json"
    path.write_text(json.dumps({"version": 1, "favorites": ["rainbow", "mosaic", "kinetic_sweep", "heart"]}))
    s = Settings(path)
    assert s["favorites"] == ["kinetic_sweep", "rainbow", "mosaic", "heart"]
    s.save()
    s["favorites"] = ["heart"]  # later user edits are respected (no re-migration)
    s.save()
    assert Settings(path)["favorites"] == ["heart"]


def test_kinetic_sweep_is_key_1_and_scene_button_1(qtbot=None):
    from apc_light.engine.registry import EffectRegistry
    from apc_light.settings.store import DEFAULTS

    reg = EffectRegistry().discover()
    keys = {c.shortcut: c.id for c in reg.all() if c.shortcut}
    assert keys["1"] == "kinetic_sweep" == DEFAULTS["favorites"][0]
    # key N == favorite N == APC scene button N
    assert [keys[str(i + 1)] for i in range(6)] == DEFAULTS["favorites"][:6]
