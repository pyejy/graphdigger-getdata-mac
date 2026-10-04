"""Synthetic test-chart generation with known ground truth (FRD risk #2)."""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from PIL import Image


@dataclass
class Chart:
    image: np.ndarray            # HxWx3 uint8
    curve_px: list[tuple[float, float]]   # ground-truth pixel polyline of main curve
    line_color: tuple[int, int, int]
    bg_color: tuple[int, int, int]
    # axis geometry (px)
    axis_x0: int; axis_x1: int; axis_y0: int; axis_y1: int
    x_min_val: float; x_max_val: float
    y_min_val: float; y_max_val: float
    log_y: bool = False


def _draw_stroke(img: np.ndarray, pts_px, color, width: int):
    """Rasterize a polyline with round disks at ~0.25px spacing (near-antialiased)."""
    h, w = img.shape[:2]
    r = max(1, width / 2.0)
    rr = math.ceil(r) + 1
    for a, b in zip(pts_px, list(pts_px)[1:] + [pts_px[-1]]):
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        n = max(1, int(seg * 4))
        for i in range(n + 1):
            t = i / n
            cx, cy = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            ix, iy = int(round(cx)), int(round(cy))
            for dy in range(-rr, rr + 1):
                for dx in range(-rr, rr + 1):
                    yy, xx = iy + dy, ix + dx
                    if 0 <= yy < h and 0 <= xx < w and dx * dx + dy * dy <= r * r + r:
                        img[yy, xx] = color


def render(size=(900, 640), *, fn=None, log_y=False, line_width=3,
           noise_dots=0, seed=7) -> Chart:
    """Render a black-on-white axes chart whose curve follows `fn(x_data)->y_data`."""
    W, H = size
    bg = (250, 250, 250)
    ink = (30, 30, 30)
    red = (210, 40, 40)
    img = np.full((H, W, 3), bg, dtype=np.uint8)

    ax_x0, ax_x1 = 80, W - 40      # plot rect in px
    ax_y0, ax_y1 = H - 60, 40      # y0 bottom pixel, y1 top pixel
    x_min_v, x_max_v = 0.0, 10.0
    if fn is None:
        fn = lambda x: 0.5 + 4.0 / (1.0 + math.exp(-(x - 5.0)))  # logistic
    y_min_v, y_max_v = (1e-1, 1e2) if log_y else (0.0, 5.0)

    def to_px(xv, yv):
        tx = (xv - x_min_v) / (x_max_v - x_min_v)
        if log_y:
            ty = (math.log10(yv) - math.log10(y_min_v)) / (math.log10(y_max_v) - math.log10(y_min_v))
        else:
            ty = (yv - y_min_v) / (y_max_v - y_min_v)
        return ax_x0 + tx * (ax_x1 - ax_x0), ax_y0 + ty * (ax_y1 - ax_y0)

    # axes lines
    for x in range(ax_x0, ax_x1 + 1):
        img[ax_y0, x] = ink
    for ypix in range(ax_y1, ax_y0 + 1):
        img[ypix, ax_x0] = ink

    # curve sampled at subpixel density, rasterized as a connected stroke
    N = 2000
    curve_px = []
    for i in range(N + 1):
        xv = x_min_v + (x_max_v - x_min_v) * i / N
        yv = fn(xv)
        px, py = to_px(xv, yv)
        curve_px.append((px, py))
    _draw_stroke(img, curve_px, red, line_width)

    rng = np.random.default_rng(seed)
    for _ in range(noise_dots):
        ny, nx = rng.integers(0, H), rng.integers(0, W)
        img[ny, nx] = red

    return Chart(image=img, curve_px=curve_px, line_color=red, bg_color=bg,
                 axis_x0=ax_x0, axis_x1=ax_x1, axis_y0=ax_y0, axis_y1=ax_y1,
                 x_min_val=x_min_v, x_max_val=x_max_v,
                 y_min_val=y_min_v, y_max_val=y_max_v, log_y=log_y)


def save(chart: Chart, path: str):
    Image.fromarray(chart.image).save(path)
