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
