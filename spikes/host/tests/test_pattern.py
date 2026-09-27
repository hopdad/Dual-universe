import subprocess

import pytest
from conftest import LUA, needs_lua

from dufleet_probe import pattern
from dufleet_probe.kit import LUA_TESTS


def test_crc8_check_value():
    assert pattern.crc8(b"123456789") == 0xF4


@pytest.mark.parametrize("bits", [1, 2])
@pytest.mark.parametrize("seq", [0, 1, 1234, 65535])
def test_header_round_trip(seq, bits):
    cells = pattern.frame_cells(seq, bits)
    assert len(cells) == pattern.CELLS
    header = pattern.decode_header(cells)
    assert header is not None and (header.seq, header.bits) == (seq, bits)


@pytest.mark.parametrize("position", range(1, 17))
def test_any_changed_header_cell_is_rejected(position):
    cells = pattern.frame_cells(1234, 2)
    cells[position] = (cells[position] + 1) % 4
    assert pattern.decode_header(cells) is None


def test_one_bit_frames_use_black_and_green_only():
    assert set(pattern.frame_cells(7, 1)) <= {0, 2}


def test_frames_differ_by_seq():
    assert pattern.frame_cells(1, 2) != pattern.frame_cells(2, 2)


@needs_lua
@pytest.mark.parametrize("bits", [1, 2])
@pytest.mark.parametrize("seq", [0, 1, 1234, 65535])
def test_lua_and_python_frames_agree(seq, bits):
    out = subprocess.run([LUA, str(LUA_TESTS / "dump_frame.lua"), str(seq), str(bits), "6", "20", "200"],
                         capture_output=True, text=True, check=True).stdout.splitlines()
    lua_cells = [int(c) for c in out[0]]
    assert lua_cells == pattern.frame_cells(seq, bits)
    svg = out[1]
    assert pattern.parse_svg(svg) == lua_cells
    assert "left:20px;top:200px" in svg and 'viewBox="0 0 56 32"' in svg and 'width="336"' in svg
    assert len(svg) < 20000
