import numpy as np
import pytest

from dufleet_probe import optical, pattern


@pytest.mark.parametrize("bits", [1, 2])
@pytest.mark.parametrize("scale", [1.0, 1.25, 1.5])
def test_decodes_synthetic_captures(bits, scale):
    img = optical.synthetic_capture(4242, bits, scale=scale)
    found = optical.locate(img)
    assert found.cell_px == pytest.approx(6 * scale, rel=0.05)
    res = optical.decode(img, optical.Sampler(found.homography, img.shape[:2]))
    assert res.ok and (res.seq, res.bits, res.errors) == (4242, bits, 0)


def test_counts_wrong_cells():
    img = optical.synthetic_capture(99, 2, scale=1.0, noise=0)
    found = optical.locate(img)
    expected = pattern.frame_cells(99, 2)
    painted = 0
    for i in range(200, 210):  # payload cells, well past the header
        r, c = divmod(i, pattern.COLS)
        (x0, y0), (x1, y1) = optical.apply(found.homography, np.array(
            [(pattern.MARGIN + c, pattern.MARGIN + r), (pattern.MARGIN + c + 1, pattern.MARGIN + r + 1)]))
        wrong = (expected[i] + 1) % 4
        img[round(y0):round(y1), round(x0):round(x1)] = pattern.PALETTE[wrong].astype(np.uint8)
        painted += 1
    res = optical.decode(img, optical.Sampler(found.homography, img.shape[:2]))
    assert res.ok and res.errors == painted


def test_no_frame_is_reported():
    rng = np.random.default_rng(1)
    img = rng.integers(20, 90, size=(300, 400, 3), dtype=np.uint8)
    with pytest.raises(LookupError):
        optical.locate(img)


def test_hidden_fiducial_is_reported():
    img = optical.synthetic_capture(5, 2, scale=1.0, noise=0)
    found = optical.locate(img)
    (x, y), = optical.apply(found.homography, np.array([pattern.FIDUCIAL_CENTERS[0]]))
    img[int(y) - 8:int(y) + 8, int(x) - 8:int(x) + 8] = 0
    res = optical.decode(img, optical.Sampler(found.homography, img.shape[:2]))
    assert not res.ok and res.reason == "fiducials not visible"


def test_find_blobs():
    mask = np.zeros((20, 30), dtype=bool)
    mask[2:6, 3:7] = True  # 4x4 square
    mask[10:12, 20:28] = True  # 2x8 bar
    mask[15:19, 2:3] = True  # an L shape joined below
    mask[18:19, 2:6] = True
    blobs = sorted(optical.find_blobs(mask), key=lambda b: b.area)
    assert [b.area for b in blobs] == [7, 16, 16]
    square = next(b for b in blobs if b.area == 16 and b.x1 - b.x0 == 3 and b.y1 - b.y0 == 3)
    assert (square.cx, square.cy) == (5.0, 4.0)
    assert square.squareish() and not blobs[0].squareish()
