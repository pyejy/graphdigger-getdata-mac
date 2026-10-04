import math
import numpy as np
import pytest

from gddigitize import core, synth


# ------------------------------------------------------------ calibration

def test_linear_roundtrip():
    ax = core.AxisCalibration(p_min=100.0, v_min=0.0, p_max=900.0, v_max=8.0)
    for v in (0.0, 1.3, 4.0, 7.9, 8.0):
        assert ax.to_value(ax.to_pixel(v)) == pytest.approx(v, rel=1e-12)


def test_log_roundtrip():
    ax = core.AxisCalibration(p_min=50.0, v_min=0.1, p_max=850.0, v_max=100.0,
                              logarithmic=True)
    for v in (0.1, 1.0, 3.14, 100.0):
        assert ax.to_value(ax.to_pixel(v)) == pytest.approx(v, rel=1e-12)


def test_log_midpoint_is_geometric():
    ax = core.AxisCalibration(p_min=0.0, v_min=1.0, p_max=100.0, v_max=1000.0,
                              logarithmic=True)
    assert ax.to_value(50.0) == pytest.approx(math.sqrt(1000.0), rel=1e-12)


def test_log_rejects_nonpositive():
    ax = core.AxisCalibration(p_min=0.0, v_min=-1.0, p_max=100.0, v_max=10.0,
                              logarithmic=True)
    with pytest.raises(ValueError):
        ax.to_value(50.0)


def test_map_2d_roundtrip():
    m = core.CalibrationMap(
        x=core.AxisCalibration(0.0, -5.0, 800.0, 5.0),
        y=core.AxisCalibration(600.0, 1.0, 40.0, 50.0, logarithmic=True))
    p = (123.5, 456.25)
    d = m.to_data(p)
    back = m.to_pixel(d)
    assert back[0] == pytest.approx(p[0], rel=1e-9)
    assert back[1] == pytest.approx(p[1], rel=1e-9)


# --------------------------------------------------------------------- mask

def test_mask_picks_red_on_white():
    c = synth.render(size=(300, 200))
    mask = core.color_mask(c.image, c.line_color, tolerance=60)
    reds = (np.abs(c.image.astype(int) - np.array(c.line_color)).sum(axis=2) < 90)
    assert mask.sum() >= reds.sum() * 0.9   # superset-ish of exact-red pixels
    assert mask.sum() < mask.size * 0.2     # nowhere near background

# ------------------------------------------------------- area digitizer acc

def _map_for(chart):
    return core.CalibrationMap(
        x=core.AxisCalibration(float(chart.axis_x0), chart.x_min_val,
                               float(chart.axis_x1), chart.x_max_val),
        y=core.AxisCalibration(float(chart.axis_y0), chart.y_min_val,
                               float(chart.axis_y1), chart.y_max_val,
                               logarithmic=chart.log_y))


def _true_curve_data(chart):
    m = _map_for(chart)
    return [m.to_data(p) for p in chart.curve_px]


def _err_stats(points, chart):
    """Relative error of digitized points vs ground-truth curve (in data space)."""
    m = _map_for(chart)
    truth_px = np.array(chart.curve_px)
    span = chart.y_max_val - chart.y_min_val if not chart.log_y else \
        (math.log10(chart.y_max_val) - math.log10(chart.y_min_val))
    errs = []
    for px, py in points:
        # true pixel y at this column by linear scan of the dense polyline
        i = int(np.argmin(np.abs(truth_px[:, 0] - px)))
        ty = truth_px[i, 1]
        dv, tv = m.y.to_value(py), m.y.to_value(ty)
        if chart.log_y:
            d_err = abs(math.log10(dv) - math.log10(tv)) / span
        else:
            d_err = abs(dv - tv) / span
        errs.append(d_err)
    return float(np.mean(errs)), float(np.percentile(errs, 95))


@pytest.mark.parametrize("dx", [4, 8])
def test_area_digitize_accuracy(dx):
    c = synth.render()
    mask = core.color_mask(c.image, c.line_color)
    rect = (c.axis_x0 + 2, c.axis_y1, c.axis_x1, c.axis_y0 - 2)
    pts = core.area_grid_digitize(mask, rect, dx=dx)
    assert len(pts) >= 90
    mean_e, p95_e = _err_stats(pts, c)
    # FRD NFR-1: clear linear charts <= 0.5% full-scale error
    assert p95_e <= 0.005, f"p95={p95_e:.4f} mean={mean_e:.4f}"


def test_area_digitize_log_axis_accuracy():
    c = synth.render(fn=lambda x: 0.2 * 10 ** (x / 3.5), log_y=True)
    mask = core.color_mask(c.image, c.line_color)
    rect = (c.axis_x0 + 2, c.axis_y1, c.axis_x1, c.axis_y0 - 2)
    pts = core.area_grid_digitize(mask, rect, dx=6)
    mean_e, p95_e = _err_stats(pts, c)
    assert p95_e <= 0.01, f"log-axis p95={p95_e:.4f}"


# ------------------------------------------------------------ trace a line

def test_trace_follows_curve_start_to_end():
    c = synth.render(noise_dots=0)
    mask = core.color_mask(c.image, c.line_color)
    start = c.curve_px[0]
    pts, branch = core.trace_line(mask, start)
    assert branch is None
    # traced endpoint should be near the true curve end
    ex, ey = pts[-1]
    tx, ty = c.curve_px[-1]
    assert abs(ex - tx) < 8 and abs(ey - ty) < 8, f"traced {len(pts)} pts, ended {(ex, ey)}"


def test_trace_bridges_dashed_line():
    c = synth.render()
    mask = core.color_mask(c.image, c.line_color)
    dashed = mask.copy()
    for gx in range(c.axis_x0 + 14, c.axis_x1 - 3, 12):
        dashed[:, gx:gx + 3] &= False
    pts, branch = core.trace_line(dashed, c.curve_px[0], bridge_px=5)
    assert len(pts) > 200                     # got across many gaps
    assert abs(pts[-1][0] - c.curve_px[-1][0]) < 15


def test_trace_stops_at_branch():
    c = synth.render()
    mask = core.color_mask(c.image, c.line_color)
    mid = len(c.curve_px) // 2
    px, py = c.curve_px[mid]
    for yy in range(int(py) - 60, int(py) + 61):
        if 0 <= yy < mask.shape[0]:
            mask[yy, int(px)] = True
    pts, branch = core.trace_line(mask, c.curve_px[0])
    assert branch is not None
    assert abs(branch[0] - px) < 15, f"branch {branch}, junction x {px}"


def test_trace_no_false_branch_on_steep_clean_curve():
    """A single steep (log-scale) curve must trace end-to-end."""
    c = synth.render(fn=lambda x: 0.2 * 10 ** (x / 3.5), log_y=True)
    mask = core.color_mask(c.image, c.line_color)
    pts, branch = core.trace_line(mask, c.curve_px[0])
    assert branch is None
    assert abs(pts[-1][0] - c.curve_px[-1][0]) < 8
