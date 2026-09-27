"""The optical test frame (spike S1), mirrored from lua/autoconf/custom/dufleet/optical.lua.

Keep the two in step: the tests compare this module's cells with the Lua probe's.
Canvas coordinates are in cells; see optical.lua for the layout.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import numpy as np

COLS, ROWS, MARGIN = 48, 24, 4
W, H = COLS + 2 * MARGIN, ROWS + 2 * MARGIN
VERSION = 1
CELLS = COLS * ROWS

# Colour indexes: 0 black, 1 red, 2 green, 3 blue. White is reserved for fiducials.
PALETTE = np.array([(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255)], dtype=np.float32)
HEX = {"#000000": 0, "#FF0000": 1, "#00FF00": 2, "#0000FF": 3}
MARKER = {1: 2, 2: 3}
ONE_BIT = {0: 0, 1: 2}
FIDUCIALS = [(1, 1), (W - 3, 1), (1, H - 3), (W - 3, H - 3)]
# Centres of the 2x2 fiducials: top-left, top-right, bottom-left, bottom-right.
FIDUCIAL_CENTERS = [(x + 1.0, y + 1.0) for x, y in FIDUCIALS]

MASK32 = 0xFFFFFFFF


def xorshift32(x: int) -> int:
    x ^= (x << 13) & MASK32
    x ^= x >> 17
    x ^= (x << 5) & MASK32
    return x


def seed(seq: int) -> int:
    x = (seq * 0x9E3779B1 + 0x7F4A7C15) & MASK32
    return x or 1


def crc8(data: bytes) -> int:
    """CRC-8/SMBUS: polynomial 0x07, initial value 0, no reflection."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def header_word(seq: int, bits: int) -> int:
    meta = (VERSION << 4) | bits
    hi, lo = (seq >> 8) & 0xFF, seq & 0xFF
    return (hi << 24) | (lo << 16) | (meta << 8) | crc8(bytes((hi, lo, meta)))


def frame_cells(seq: int, bits: int) -> list[int]:
    """Colour index of every data cell, row by row."""
    if bits not in (1, 2):
        raise ValueError("bits must be 1 or 2")
    seq &= 0xFFFF
    mask = (1 << bits) - 1

    def colour(symbol: int) -> int:
        return ONE_BIT[symbol] if bits == 1 else symbol

    cells = [MARKER[bits]]
    word = header_word(seq, bits)
    header_cells = 32 // bits
    for k in range(header_cells):
        cells.append(colour((word >> (32 - bits * (k + 1))) & mask))
    x = seed(seq)
    for _ in range(header_cells + 1, CELLS):
        x = xorshift32(x)
        cells.append(colour((x >> 24) & mask))
    return cells


@dataclass
class Header:
    seq: int
    bits: int


def decode_header(cells: list[int]) -> Header | None:
    """Reads the mode marker and the 32-bit header; None if either is invalid."""
    bits = {3: 2, 2: 1}.get(cells[0])
    if bits is None:
        return None
    header_cells = 32 // bits
    word = 0
    for k in range(header_cells):
        value = cells[1 + k]
        if bits == 1:
            if value not in (0, 2):
                return None
            symbol = 1 if value == 2 else 0
        else:
            symbol = value
        word = (word << bits) | symbol
    hi, lo, meta, crc = (word >> 24) & 0xFF, (word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF
    if meta != ((VERSION << 4) | bits) or crc8(bytes((hi, lo, meta))) != crc:
        return None
    return Header(seq=(hi << 8) | lo, bits=bits)


def render(cells: list[int], cell_px: int) -> np.ndarray:
    """The frame as an RGB image, one solid square per cell, like the SVG draws it."""
    grid = np.zeros((H, W, 3), dtype=np.uint8)
    for fx, fy in FIDUCIALS:
        grid[fy:fy + 2, fx:fx + 2] = 255
    data = PALETTE.astype(np.uint8)[np.asarray(cells, dtype=np.int64).reshape(ROWS, COLS)]
    grid[MARGIN:MARGIN + ROWS, MARGIN:MARGIN + COLS] = data
    return np.repeat(np.repeat(grid, cell_px, axis=0), cell_px, axis=1)


_PATH = re.compile(r'<path fill="(#[0-9A-F]{6})" stroke="none" d="([^"]*)"/>')
_RUN = re.compile(r"M(\d+) (\d+)h(\d+)v1h-(\d+)z")


def parse_svg(svg: str) -> list[int]:
    """Reads the cells back out of the probe's SVG (for the parity tests)."""
    cells = [0] * CELLS
    for colour, d in _PATH.findall(svg):
        index = HEX[colour]
        for x, y, n, n2 in _RUN.findall(d):
            x, y, n = int(x), int(y), int(n)
            if n != int(n2):
                raise ValueError(f"malformed run at {x},{y}")
            for k in range(n):
                cells[(y - MARGIN) * COLS + (x - MARGIN) + k] = index
    return cells
