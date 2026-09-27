"""Spike S1: find the probe's optical frame on screen, then decode and score it.

`locate` finds the four white fiducials in one screenshot and saves a calibration
(capture region plus a homography from canvas cells to region pixels). `watch`
captures that region repeatedly, decodes each capture, and compares every cell
with the pattern the header promises. `selftest` runs the decoder on synthetic
captures, no game needed.
"""

from __future__ import annotations

import math
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from dufleet_probe import pattern
from dufleet_probe.kit import load_json, save_json

WHITE_MIN = 200  # every channel of a fiducial pixel is at least this bright
FIDUCIAL_MIN = 150  # when checking known fiducial positions during watch
LOW_CONFIDENCE = 40.0  # colour-distance margin below which a cell counts as doubtful

_OFFSETS = np.array([(dx, dy) for dy in (-0.2, 0.0, 0.2) for dx in (-0.2, 0.0, 0.2)])


@dataclass
class Blob:
    area: int
    cx: float
    cy: float
    x0: int
    y0: int
    x1: int
    y1: int

    def squareish(self) -> bool:
        bw, bh = self.x1 - self.x0 + 1, self.y1 - self.y0 + 1
        return 9 <= self.area <= 20000 and 0.6 <= bw / bh <= 1.6 and self.area / (bw * bh) >= 0.7


def find_blobs(mask: np.ndarray, max_runs: int = 400_000) -> list[Blob]:
    """4-connected components of a boolean mask, via union-find over row runs."""
    height, width = mask.shape
    parent: list[int] = []
    runs: list[tuple[int, int, int]] = []  # (row, start, end exclusive)

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    padded = np.zeros(width + 2, dtype=np.int8)
    prev: list[int] = []
    for y in range(height):
        row = mask[y]
        if not row.any():
            prev = []
            continue
        padded[1:-1] = row
        edges = np.diff(padded)
        cur: list[int] = []
        j = 0
        starts, ends = np.flatnonzero(edges == 1).tolist(), np.flatnonzero(edges == -1).tolist()
        for s, e in zip(starts, ends, strict=True):
            idx = len(runs)
            runs.append((y, s, e))
            parent.append(idx)
            cur.append(idx)
            while j < len(prev) and runs[prev[j]][2] <= s:
                j += 1
            k = j
            while k < len(prev) and runs[prev[k]][1] < e:
                a, b = find(idx), find(prev[k])
                if a != b:
                    parent[a] = b
                k += 1
        if len(runs) > max_runs:
            raise RuntimeError("too many bright areas on screen; pass --region to narrow the search")
        prev = cur

    acc: dict[int, list[float]] = {}
    for i, (y, s, e) in enumerate(runs):
        n = e - s
        a = acc.setdefault(find(i), [0, 0.0, 0.0, s, y, e - 1, y])
        a[0] += n
        a[1] += n * (s + e - 1) / 2
        a[2] += n * y
        a[3], a[4] = min(a[3], s), min(a[4], y)
        a[5], a[6] = max(a[5], e - 1), max(a[6], y)
    return [
        Blob(int(a[0]), a[1] / a[0] + 0.5, a[2] / a[0] + 0.5, int(a[3]), int(a[4]), int(a[5]), int(a[6]))
        for a in acc.values()
    ]


def homography(src: list[tuple[float, float]], dst: list[tuple[float, float]]) -> np.ndarray:
    rows = []
    for (u, v), (x, y) in zip(src, dst, strict=True):
        rows.append([u, v, 1, 0, 0, 0, -x * u, -x * v, -x])
        rows.append([0, 0, 0, u, v, 1, -y * u, -y * v, -y])
    _, _, vt = np.linalg.svd(np.asarray(rows, dtype=np.float64))
    hm = vt[-1].reshape(3, 3)
    return hm / hm[2, 2]


def apply(hm: np.ndarray, pts: np.ndarray) -> np.ndarray:
    pts = np.asarray(pts, dtype=np.float64)
    ones = np.ones((pts.shape[0], 1))
    out = np.hstack([pts, ones]) @ hm.T
    return out[:, :2] / out[:, 2:3]


@dataclass
class Found:
    homography: np.ndarray  # canvas cells -> image pixels
    cell_px: float
    corners: list[tuple[float, float]]  # fiducial centres: TL, TR, BL, BR


def _nearest(blobs: list[Blob], x: float, y: float, tol: float) -> Blob | None:
    best, best_d = None, tol
    for b in blobs:
        d = math.hypot(b.cx - x, b.cy - y)
        if d <= best_d:
            best, best_d = b, d
    return best


def locate(img: np.ndarray) -> Found:
    mask = (img[..., 0] >= WHITE_MIN) & (img[..., 1] >= WHITE_MIN) & (img[..., 2] >= WHITE_MIN)
    blobs = [b for b in find_blobs(mask) if b.squareish()]
    span_x, span_y = pattern.W - 4, pattern.H - 4  # distance between fiducial centres, in cells
    want = span_x / span_y
    best = None
    for tl in blobs:
        for br in blobs:
            dx, dy = br.cx - tl.cx, br.cy - tl.cy
            if dx <= 0 or dy <= 0:
                continue
            ratio_err = abs((dx / dy) / want - 1)
            if ratio_err > 0.12:
                continue
            cell = dx / span_x
            side = math.sqrt(tl.area) / 2  # a fiducial is 2 x 2 cells
            if not 0.6 < side / cell < 1.5:
                continue
            tr = _nearest(blobs, br.cx, tl.cy, cell * 0.6)
            bl = _nearest(blobs, tl.cx, br.cy, cell * 0.6)
            if tr is None or bl is None:
                continue
            score = ratio_err + 0.1 * abs(side / cell - 1)
            if best is None or score < best[0]:
                best = (score, tl, tr, bl, br, cell)
    if best is None:
        raise LookupError("optical frame not found: is it on (/b frame on) and uncovered?")
    _, tl, tr, bl, br, cell = best
    corners = [(tl.cx, tl.cy), (tr.cx, tr.cy), (bl.cx, bl.cy), (br.cx, br.cy)]
    return Found(homography(pattern.FIDUCIAL_CENTERS, corners), cell, corners)


class Sampler:
    """Pixel positions to read for every data cell and fiducial, for one calibration."""

    def __init__(self, hm: np.ndarray, shape: tuple[int, int]):
        height, width = shape
        cu, cv = np.meshgrid(
            np.arange(pattern.COLS) + pattern.MARGIN + 0.5, np.arange(pattern.ROWS) + pattern.MARGIN + 0.5
        )
        centres = np.stack([cu.ravel(), cv.ravel()], axis=1)
        self.cell_xy = self._pixels(hm, centres, width, height)
        fid = np.asarray(pattern.FIDUCIAL_CENTERS)
        self.fid_xy = self._pixels(hm, fid, width, height, spread=2.0)

    @staticmethod
    def _pixels(hm, centres, width, height, spread=1.0):
        pts = (centres[:, None, :] + spread * _OFFSETS[None, :, :]).reshape(-1, 2)
        img = apply(hm, pts)
        xs = np.clip(np.floor(img[:, 0]).astype(np.int64), 0, width - 1).reshape(len(centres), -1)
        ys = np.clip(np.floor(img[:, 1]).astype(np.int64), 0, height - 1).reshape(len(centres), -1)
        return xs, ys

    def cell_colours(self, img: np.ndarray) -> np.ndarray:
        xs, ys = self.cell_xy
        return img[ys, xs].astype(np.float32).mean(axis=1)

    def fiducial_colours(self, img: np.ndarray) -> np.ndarray:
        xs, ys = self.fid_xy
        return img[ys, xs].astype(np.float32).mean(axis=1)


@dataclass
class Decoded:
    ok: bool
    reason: str = ""
    seq: int | None = None
    bits: int | None = None
    errors: int = 0
    low_confidence: int = 0


def decode(img: np.ndarray, sampler: Sampler) -> Decoded:
    if (sampler.fiducial_colours(img).min(axis=1) < FIDUCIAL_MIN).any():
        return Decoded(False, "fiducials not visible")
    colours = sampler.cell_colours(img)
    dist = np.sqrt(((colours[:, None, :] - pattern.PALETTE[None, :, :]) ** 2).sum(axis=2))
    order = np.argsort(dist, axis=1)
    idx = order[:, 0]
    margin = np.take_along_axis(dist, order[:, 1:2], 1)[:, 0] - np.take_along_axis(dist, order[:, :1], 1)[:, 0]
    low = int((margin < LOW_CONFIDENCE).sum())
    header = pattern.decode_header(idx.tolist())
    if header is None:
        return Decoded(False, "header unreadable", low_confidence=low)
    expected = np.asarray(pattern.frame_cells(header.seq, header.bits))
    return Decoded(True, seq=header.seq, bits=header.bits, errors=int((idx != expected).sum()), low_confidence=low)


def synthetic_capture(seq: int, bits: int, *, cell_px: int = 6, scale: float = 1.25, noise: float = 6.0,
                      offset: tuple[int, int] = (137, 91), size: tuple[int, int] = (640, 420),
                      seed: int = 7) -> np.ndarray:
    """A screenshot-like image of one frame: dark noisy background, resampled, noisy."""
    from PIL import Image

    rng = np.random.default_rng(seed)
    frame = pattern.render(pattern.frame_cells(seq, bits), cell_px)
    canvas = rng.integers(20, 90, size=(size[1], size[0], 3), dtype=np.uint8)
    ox, oy = offset
    canvas[oy:oy + frame.shape[0], ox:ox + frame.shape[1]] = frame
    if scale != 1.0:
        im = Image.fromarray(canvas).resize((round(size[0] * scale), round(size[1] * scale)), Image.BILINEAR)
        canvas = np.asarray(im)
    if noise > 0:
        canvas = np.clip(canvas.astype(np.float32) + rng.normal(0, noise, canvas.shape), 0, 255).astype(np.uint8)
    return canvas


# --- commands -----------------------------------------------------------------


def _grab(sct, region: dict) -> np.ndarray:
    shot = np.asarray(sct.grab(region))  # BGRA
    return shot[:, :, 2::-1].copy()  # RGB


def _parse_region(text: str | None) -> dict | None:
    if not text:
        return None
    left, top, width, height = (int(v) for v in text.split(","))
    return {"left": left, "top": top, "width": width, "height": height}


def _save_png(img: np.ndarray, path: Path, marks: list[tuple[float, float]] | None = None) -> None:
    from PIL import Image, ImageDraw

    im = Image.fromarray(img)
    if marks:
        draw = ImageDraw.Draw(im)
        for x, y in marks:
            draw.ellipse((x - 5, y - 5, x + 5, y + 5), outline=(255, 0, 255), width=2)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path)


def cmd_locate(args) -> int:
    import mss

    with mss.mss() as sct:
        monitor = sct.monitors[args.monitor]
        region = _parse_region(args.region) or {k: monitor[k] for k in ("left", "top", "width", "height")}
        img = _grab(sct, region)
    try:
        found = locate(img)
    except LookupError as exc:
        _save_png(img, args.results / "optical_locate_failed.png")
        print(f"{exc}\nSaved the screenshot to {args.results / 'optical_locate_failed.png'}")
        return 1
    corners = apply(found.homography, np.array([(0, 0), (pattern.W, 0), (0, pattern.H), (pattern.W, pattern.H)]))
    pad = found.cell_px * 2
    h_img, w_img = img.shape[:2]
    x0, y0 = max(0, math.floor(corners[:, 0].min() - pad)), max(0, math.floor(corners[:, 1].min() - pad))
    x1, y1 = min(w_img, math.ceil(corners[:, 0].max() + pad)), min(h_img, math.ceil(corners[:, 1].max() + pad))
    shift = np.array([[1, 0, -x0], [0, 1, -y0], [0, 0, 1]], dtype=np.float64)
    calibration = {
        "monitor": args.monitor,
        "region": {"left": region["left"] + x0, "top": region["top"] + y0, "width": x1 - x0, "height": y1 - y0},
        "homography": (shift @ found.homography).tolist(),
        "cell_px": found.cell_px,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    path = save_json(args.results, "optical_calibration.json", calibration)
    crop = img[y0:y1, x0:x1]
    _save_png(crop, args.results / "optical_locate.png", [(x - x0, y - y0) for x, y in found.corners])
    print(f"Frame found: cell {found.cell_px:.2f} px, region {calibration['region']}")
    print(f"Calibration: {path}")
    print(f"Check the circles in {args.results / 'optical_locate.png'} sit on the four white squares.")
    return 0


def cmd_watch(args) -> int:
    import mss

    cal_path = Path(args.calibration) if args.calibration else args.results / "optical_calibration.json"
    cal = load_json(cal_path)
    region = cal["region"]
    sampler = Sampler(np.asarray(cal["homography"]), (region["height"], region["width"]))
    reasons: Counter[str] = Counter()
    first_seen: dict[int, float] = {}
    clean: set[int] = set()
    errors: list[int] = []
    low: list[int] = []
    decode_ms: list[float] = []
    bits_seen: Counter[int] = Counter()
    captures = saved = 0
    period = 1.0 / args.hz
    start = time.monotonic()
    print(f"Watching {region} for {args.duration} s at up to {args.hz} captures per second...")
    with mss.mss() as sct:
        while time.monotonic() - start < args.duration:
            t = time.monotonic()
            img = _grab(sct, region)
            captures += 1
            t0 = time.perf_counter()
            res = decode(img, sampler)
            decode_ms.append((time.perf_counter() - t0) * 1000)
            if res.ok:
                bits_seen[res.bits] += 1
                errors.append(res.errors)
                low.append(res.low_confidence)
                first_seen.setdefault(res.seq, t - start)
                if res.errors == 0:
                    clean.add(res.seq)
            else:
                reasons[res.reason] += 1
            if (not res.ok or res.errors > 0) and saved < 5:
                saved += 1
                _save_png(img, args.results / f"optical_fail_{saved}.png")
            time.sleep(max(0.0, period - (time.monotonic() - t)))
    elapsed = time.monotonic() - start
    order = sorted(first_seen, key=first_seen.get)
    gaps = sum((b - a - 1) % 65536 for a, b in zip(order, order[1:], strict=False))
    summary = {
        "region": region,
        "cell_px": cal.get("cell_px"),
        "elapsed_s": round(elapsed, 1),
        "captures": captures,
        "decoded": len(errors),
        "not_decoded": dict(reasons),
        "unique_frames": len(first_seen),
        "clean_frames": len(clean),
        "frames_per_s": round(len(first_seen) / elapsed, 2) if elapsed else 0,
        "missed_frames": gaps,
        "bits_seen": dict(bits_seen),
        "cell_errors_mean": round(float(np.mean(errors)), 2) if errors else None,
        "cell_errors_max": max(errors) if errors else None,
        "captures_error_free_pct": round(100 * sum(e == 0 for e in errors) / len(errors), 1) if errors else None,
        "low_confidence_mean": round(float(np.mean(low)), 2) if low else None,
        "decode_ms_mean": round(float(np.mean(decode_ms)), 2) if decode_ms else None,
        "failure_pngs": saved,
    }
    path = save_json(args.results, "s1_optical.json", summary)
    for k, v in summary.items():
        print(f"  {k}: {v}")
    print(f"Saved {path}")
    return 0


def cmd_selftest(args) -> int:
    ok = True
    for bits in (2, 1):
        for scale in (1.0, 1.25, 1.5):
            img = synthetic_capture(4242, bits, scale=scale)
            found = locate(img)
            res = decode(img, Sampler(found.homography, img.shape[:2]))
            good = res.ok and res.seq == 4242 and res.errors == 0
            ok &= good
            print(f"bits {bits} scale {scale}: {'OK' if good else 'FAIL'} "
                  f"(cell {found.cell_px:.2f} px, errors {res.errors}, doubtful {res.low_confidence})")
    print("selftest passed" if ok else "selftest FAILED")
    return 0 if ok else 1


def add_parser(sub) -> None:
    p = sub.add_parser("optical", help="S1: locate, watch or self-test the optical frame")
    osub = p.add_subparsers(dest="optical_cmd", required=True)
    loc = osub.add_parser("locate", help="find the frame on screen and save a calibration")
    loc.add_argument("--monitor", type=int, default=1, help="mss monitor number (1 = primary)")
    loc.add_argument("--region", help="search only LEFT,TOP,WIDTH,HEIGHT (screen pixels)")
    loc.set_defaults(func=cmd_locate)
    watch = osub.add_parser("watch", help="decode the frame repeatedly and report error rates")
    watch.add_argument("--duration", type=float, default=120)
    watch.add_argument("--hz", type=float, default=10, help="captures per second")
    watch.add_argument("--calibration", help="calibration file (default: results/optical_calibration.json)")
    watch.set_defaults(func=cmd_watch)
    st = osub.add_parser("selftest", help="decode synthetic frames; no game needed")
    st.set_defaults(func=cmd_selftest)
