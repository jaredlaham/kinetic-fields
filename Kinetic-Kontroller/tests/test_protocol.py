from apc_light.midi import protocol as p
from apc_light.midi.palette import PALETTE, nearest_index


def test_pad_mapping_corners():
    assert p.xy_to_note(0, 7) == 0      # bottom-left
    assert p.xy_to_note(7, 7) == 7      # bottom-right
    assert p.xy_to_note(0, 0) == 56     # top-left
    assert p.xy_to_note(7, 0) == 63     # top-right
    for n in range(64):
        assert p.xy_to_note(*p.note_to_xy(n)) == n


def test_note_on_brightness_channels():
    assert p.note_on(5, 5, 6) == [0x96, 5, 5]
    assert p.brightness_channel(100) == 6
    assert p.brightness_channel(10) == 0
    assert p.brightness_channel(0) == 0
    assert p.brightness_channel(70) in (3, 4)


def test_sysex_format_and_chunking():
    msgs = p.rgb_sysex([(0, 0, (255, 128, 1))])
    assert msgs == [[0xF0, 0x47, 0x7F, 0x4F, 0x24, 0, 8, 0, 0, 1, 0x7F, 1, 0, 0, 1, 0xF7]]
    blocks = [(i, i, (i, 0, 0)) for i in range(64)]
    msgs = p.rgb_sysex(blocks)
    assert len(msgs) == 2
    for m in msgs:
        assert m[5] << 7 | m[6] == 32 * 8
        assert m[-1] == 0xF7


def test_runs_compress_contiguous_colours():
    runs = p.rgb_runs([(3, (1, 1, 1)), (1, (1, 1, 1)), (2, (1, 1, 1)), (5, (1, 1, 1)), (6, (2, 2, 2))])
    assert runs == [(1, 3, (1, 1, 1)), (5, 5, (1, 1, 1)), (6, 6, (2, 2, 2))]


def test_palette():
    assert len(PALETTE) == 128
    assert nearest_index((255, 0, 0)) == 5
    assert nearest_index((0, 0, 0)) == 0
    assert nearest_index((1, 1, 1)) != 0  # anything non-black stays lit
