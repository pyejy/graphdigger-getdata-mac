"""Core domain algorithms for the GetData-replica prototype (Phase 0).

Pure logic, no UI dependencies. Mirrors GDCore in the architecture doc:
CalibrationMap / ColorMask / AreaGridDigitizer / TraceLineDigitizer.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable, Iterator, Optional

import numpy as np

Point = tuple[float, float]


# ---------------------------------------------------------------- calibration

@dataclass
class AxisCalibration:
    """Two pixel anchors with known values; linear or log10 scale."""
    p_min: float
    v_min: float
    p_max: float
    v_max: float
    logarithmic: bool = False

    def to_value(self, p: float) -> float:
        if self.p_max == self.p_min:
            raise ValueError("degenerate axis")
        if self.logarithmic and min(self.v_min, self.v_max) <= 0:
            raise ValueError("log scale requires positive values")
        t = (p - self.p_min) / (self.p_max - self.p_min)
        if self.logarithmic:
            lv0, lv1 = math.log10(self.v_min), math.log10(self.v_max)
            return 10.0 ** (lv0 + t * (lv1 - lv0))
        return self.v_min + t * (self.v_max - self.v_min)

    def to_pixel(self, v: float) -> float:
        if self.p_max == self.p_min:
            raise ValueError("degenerate axis")
        if self.logarithmic:
            if min(self.v_min, self.v_max) <= 0:
                raise ValueError("log scale requires positive values")
            if v <= 0:
                raise ValueError("log scale requires positive value")
            lv0, lv1 = math.log10(self.v_min), math.log10(self.v_max)
            t = (math.log10(v) - lv0) / (lv1 - lv0)
        else:
            if self.v_max == self.v_min:
                raise ValueError("degenerate axis")
            t = (v - self.v_min) / (self.v_max - self.v_min)
        return self.p_min + t * (self.p_max - self.p_min)


@dataclass
class CalibrationMap:
    x: AxisCalibration
    y: AxisCalibration

    def to_data(self, p: Point) -> Point:
        return (self.x.to_value(p[0]), self.y.to_value(p[1]))

    def to_pixel(self, d: Point) -> Point:
        return (self.x.to_pixel(d[0]), self.y.to_pixel(d[1]))


# --------------------------------------------------------------------- mask

def color_mask(image: np.ndarray, line_color, tolerance: int = 60) -> np.ndarray:
    """Weighted-RGB euclidean distance thresholding against background/other colors.

    image: HxWx3 uint8. Returns boolean mask of foreground pixels.
    """
    img = image.astype(np.float32)
    lc = np.asarray(line_color, dtype=np.float32)
    diff = img - lc
    w = np.array([2.0, 4.0, 3.0], dtype=np.float32)  # R,G,B weights (classic 2-4-3)
    dist = np.sqrt(((diff * w) ** 2).sum(axis=2) / (w ** 2).sum())
    return dist <= tolerance


# -------------------------------------------------------- area grid digitize

def area_grid_digitize(mask: np.ndarray, rect: tuple[int, int, int, int],
                       dx: int) -> list[Point]:
    """FR-5.2: vertical scan lines spaced `dx` px within rect; each column's
    foreground run(s) yield centroid point(s). A run is broken when a gap
    longer than `gap` (=max(2, dx//3)) consecutive empty rows appears, so two
    crossing curves produce two points on that column instead of one merged.
    """
    x0, y0, x1, y1 = rect
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(mask.shape[1] - 1, x1), min(mask.shape[0] - 1, y1)
    gap = max(3, dx)
    pts: list[Point] = []
    x = x0
    while x <= x1:
        col = mask[y0:y1 + 1, x]
        ys = np.flatnonzero(col)
        if ys.size:
            runs: list[list[int]] = [[ys[0]]]
            prev = ys[0]
            for yy in ys[1:]:
                if yy - prev > gap:
                    runs.append([yy])
                else:
                    runs[-1].append(yy)
                prev = yy
            for run in runs:
                pts.append((float(x), y0 + (sum(run) + len(run) / 2.0) / len(run)))
        x += dx
    return pts


# ------------------------------------------------------------ trace a line

_DIRS = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def _norm(a: float) -> float:
    return (a + math.pi) % (2 * math.pi) - math.pi


def trace_line(mask: np.ndarray, start: Point, *, bridge_px: int = 4,
               R: int = 7, min_lat: float = 2.0, persist: int = 3,
               div_fwd: float = 3.0, fan_deg: float = 70.0,
               max_points: int = 200_000) -> tuple[list[Point], Optional[Point]]:
    """FR-5.1: walk along the connected stroke from `start`.

    Directional walker with a perpendicular-profile junction detector:
    at each step we scan lateral profiles along the travel axis (depths
    2..R). A side is "occupied" when an unvisited foreground cluster sits
    beyond min_lat px off-axis; occupancy must persist for `persist` steps
    on BOTH sides, and the extreme offsets' deepest observed depths must
    differ by >= div_fwd px (two diverging strokes), before we stop and
    report the nearer-to-axis branch cell. This does not fire on stroke
    thickness or on a single steeply-deviating curve because those occupy
    only one side of travel or spread symmetrically. Gaps up to bridge_px
    are bridged along the heading (dashed strokes).

    Returns (ordered points, branch_point_or_None).
    """
    h, w = mask.shape
    sx, sy = int(round(start[0])), int(round(start[1]))
    if not (0 <= sx < w and 0 <= sy < h) or not mask[sy, sx]:
        raise ValueError("start not on foreground")

    visited = np.zeros_like(mask, dtype=bool)
    pts: list[Point] = [(float(sx), float(sy))]
    cur = (sx, sy)
    visited[sy, sx] = True
    heading = None
    pos_run = neg_run = 0
    fp = fn = None

    def free(p):
        out = []
        for ox, oy in _DIRS:
            nx, ny = p[0] + ox, p[1] + oy
            if 0 <= nx < w and 0 <= ny < h and mask[ny, nx] and not visited[ny, nx]:
                out.append((nx, ny))
        return out

    while len(pts) < max_points:
        cand = free(cur)
        chosen = None
        ux, uy = (math.cos(heading), math.sin(heading)) if heading is not None else (1.0, 0.0)
        if heading is None:
            pref = [q for q in cand if q[0] > cur[0]] or cand
            if not pref:
                break
            chosen = min(pref, key=lambda q: abs(q[1] - cur[1]))
        else:
            scored = sorted(
                ((abs(_norm(math.atan2(q[1] - cur[1], q[0] - cur[0]) - heading)), q)
                 for q in cand), key=lambda s: s[0])
            fwd_ok = [(d, q) for d, q in scored if d <= math.radians(fan_deg)]
            if fwd_ok:
                best_d = min(d for d, _ in fwd_ok)
                pool = [q for d, q in fwd_ok if d <= best_d + math.radians(35)]
                chosen = max(pool, key=lambda q: (q[0] - cur[0]) * ux + (q[1] - cur[1]) * uy)
        if chosen is None:
            landed = None
            if heading is not None:
                # cone search ahead of cur; additionally try rays at +/-8 deg
                # offsets so a slight heading drift does not miss the far dash
                # segment. Nearest foreground cell within bridge_px wins.
                for off_deg in (0.0, 8.0, -8.0):
                    hd = heading + math.radians(off_deg)
                    rx, ry = math.cos(hd), math.sin(hd)
                    best_d = None
                    for k10 in range(10, (bridge_px + 1) * 10):
                        kk = k10 / 10.0
                        fx, fy = int(round(cur[0] + rx * kk)), int(round(cur[1] + ry * kk))
                        if not (0 <= fx < w and 0 <= fy < h):
                            continue
                        if visited[fy, fx] or not mask[fy, fx]:
                            continue
                        ang = abs(_norm(math.atan2(fy - cur[1], fx - cur[0]) - heading))
                        if ang <= math.radians(45):
                            d = math.hypot(fx - cur[0], fy - cur[1])
                            if best_d is None or d < best_d:
                                best_d, cand_landed = d, (fx, fy)
                    if best_d is not None and (landed is None or best_d < landed[0]):
                        landed = (best_d, cand_landed)
                if landed is not None:
                    landed = landed[1]
            if landed is None:
                break  # line end / unrecoverable gap
            cur = landed
            visited[cur[1], cur[0]] = True
            pts.append((float(cur[0]), float(cur[1])))
            continue

        visited[chosen[1], chosen[0]] = True
        cur = chosen
        pts.append((float(cur[0]), float(cur[1])))
        win = pts[max(0, len(pts) - 13):]
        vx = sum(b[0] - a[0] for a, b in zip(win, win[1:]))
        vy = sum(b[1] - a[1] for a, b in zip(win, win[1:]))
        if abs(vx) + abs(vy) > 0:
            raw = math.atan2(vy, vx)
            heading = raw if heading is None else heading + 0.5 * _norm(raw - heading)

        # ---- perpendicular profiles along travel ----------------------------
        tx, ty = math.cos(heading), math.sin(heading)
        sx_, sy_ = -ty, tx
        profiles: dict[int, tuple[list[float], list[float]]] = {}
        for step in range(2, R + 1):
            ix, iy = int(round(cur[0] + tx * step)), int(round(cur[1] + ty * step))
            if not (0 <= ix < w and 0 <= iy < h):
                break
            offs = []
            for off in range(-R, R + 1):
                ox_, oy_ = int(round(ix + sx_ * off)), int(round(iy + sy_ * off))
                if 0 <= ox_ < w and 0 <= oy_ < h and mask[oy_, ox_] and not visited[oy_, ox_]:
                    offs.append(off)
            cl = []
            for k in sorted(offs):
                if cl and k - cl[-1][-1] <= 1:
                    cl[-1].append(k)
                else:
                    cl.append([k])
            centres = [sum(c) / len(c) for c in cl]
            rp = [o for o in centres if o >= min_lat]
            rn = [o for o in centres if o <= -min_lat]
            if rp or rn:
                profiles[step] = (rp, rn)
        seen_pos = any(rp for rp, rn in profiles.values())
        seen_neg = any(rn for rp, rn in profiles.values())
        pos_run = pos_run + 1 if seen_pos else 0
        neg_run = neg_run + 1 if seen_neg else 0

        def extreme(want_pos):
            vals = [(o, s) for s, (rp, rn) in profiles.items()
                    for o in (rp if want_pos else rn)]
            if not vals:
                return None
            o = max(o for o, _ in vals) if want_pos else min(o for o, _ in vals)
            dep = max(s for oo, s in vals if oo == o)
            return (dep, o)

        p = extreme(True); n = extreme(False)
        if p:
            fp = p
        if n:
            fn = n
        if pos_run >= persist and neg_run >= persist and fp and fn:
            if abs(fp[0] - fn[0]) >= div_fwd:      # strokes diverge ahead
                step, side = fp if abs(fp[1]) <= abs(fn[1]) else fn
                bx = int(round(cur[0] + tx * step + sx_ * side))
                by = int(round(cur[1] + ty * step + sy_ * side))
                if 0 <= bx < w and 0 <= by < h and mask[by, bx]:
                    return pts, (float(bx), float(by))
    return pts, None
