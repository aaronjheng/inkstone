# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "resvg-py"]
# ///
"""Generate the Inkstone app icon (all 10 AppIcon sizes).

Pipeline mirrors Canoe's: the icon is drawn as SVG, rendered to a 2048
master with resvg, then downscaled with Pillow. Everything stays in memory;
only the 10 PNGs (and `--preview`, if given) touch disk.

Design: a loaded calligraphy brush above one sweeping S stroke, both reduced
to geometric primitives. The blade is a razor wedge cut by a concave ferrule
arc; the hair is a true teardrop (tangents from the drop tip to the circle
concentric with the ferrule arc, offset inward by the gap, so the white
crescent stays parallel); the stroke is the reference sweep contour tilted
-8 deg. Bold for Dock sizes: pure white plate, heavy marks, composition
pulled toward the centre with even margins all around.

Usage:
    uv run Tools/gen_appicon.py [--preview /tmp/inkstone_icon_master.png]

Writes the 10 PNGs into Assets.xcassets/Inkstone.appiconset/.
"""

import argparse
import io
import json
import math
import sys
from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets.xcassets"
ICONSET = ASSETS / "Inkstone.appiconset"

# ---- palette ----
PAPER = "#FFFFFF"
INK = "#1B1D1E"

# ---- geometry (1024-space) ----
TILE_R = 225
GROUP_SCALE = 0.82  # whole composition about the tile centre

# blade (笔杆/锋): razor wedge, concave ferrule cut at the base
BLADE_TIP = (836.0, 112.0)
BLADE_ANGLE = 127.0   # y-down degrees, tip -> base
BLADE_LEN = 338.0
BLADE_HALF_W = 54.0
FERRULE_SAG = 19.0    # depth of the concave cut

# hair (笔毫): teardrop tangent to the inward-offset ferrule circle
HAIR_GAP = 20.0
HAIR_TIP = (488.0, 614.0)

# sweep (墨痕): contour sampled from the reference mask
SWEEP = (
    "M501.4 542.8L431.6 572.1L401.3 588.3L379.1 603.5L361.9 620.7L354.8 634.8"
    "L354.8 646.9L364.9 660.1L387.2 670.2L426.6 677.3L470.0 679.3L558.0 679.3"
    "L637.9 683.3L692.4 690.4L750.1 704.6L770.3 712.7L796.6 727.8L808.7 738.9"
    "L816.8 751.1L821.8 770.3L820.8 781.4L812.7 801.6L801.6 816.8L783.4 834.0"
    "L763.2 848.1L720.7 870.3L662.1 891.6L587.3 908.8L514.5 917.9L427.6 918.9"
    "L373.0 912.8L328.5 899.7L361.9 883.5L466.0 845.1L518.6 819.8L538.8 807.7"
    "L561.0 788.5L567.1 777.4L566.1 766.2L557.0 757.1L546.9 752.1L515.5 745.0"
    "L477.1 742.0L345.7 739.9L304.3 735.9L270.9 729.8L236.5 717.7L225.4 710.6"
    "L217.3 702.5L211.3 689.4L213.3 670.2L228.5 646.9L248.7 628.8L272.9 612.6"
    "L308.3 594.4L346.7 579.2L385.1 567.1L439.7 554.0L500.4 543.8Z"
)
SWEEP_CX, SWEEP_CY = (211.3 + 821.8) / 2, (542.8 + 918.9) / 2
SWEEP_TILT = -8.0
SWEEP_SCALE = 1.22
SWEEP_AT = (490.0, 660.0)

RENDER_PX = 2048

SIZES = {
    "icon_512x512@2x.png": 1024,
    "icon_512x512.png": 512,
    "icon_256x256@2x.png": 512,
    "icon_256x256.png": 256,
    "icon_128x128@2x.png": 256,
    "icon_128x128.png": 128,
    "icon_32x32@2x.png": 64,
    "icon_32x32.png": 32,
    "icon_16x16@2x.png": 32,
    "icon_16x16.png": 16,
}


def _rad(deg: float) -> float:
    return math.radians(deg)


def blade_and_hair() -> tuple[str, str]:
    """Wedge blade with concave ferrule cut + geometric teardrop hair."""
    a = _rad(BLADE_ANGLE)
    dx, dy = math.cos(a), math.sin(a)
    nx, ny = -dy, dx
    base = (
        BLADE_TIP[0] + BLADE_LEN * dx,
        BLADE_TIP[1] + BLADE_LEN * dy,
    )
    cl = (base[0] + BLADE_HALF_W * nx, base[1] + BLADE_HALF_W * ny)
    cr = (base[0] - BLADE_HALF_W * nx, base[1] - BLADE_HALF_W * ny)
    # ferrule arc through cl, cr with sagitta FERRULE_SAG toward the tip
    r = (BLADE_HALF_W**2 + FERRULE_SAG**2) / (2 * FERRULE_SAG)
    cb = (
        base[0] + (r - FERRULE_SAG) * dx,
        base[1] + (r - FERRULE_SAG) * dy,
    )

    def arc(a0: float, a1: float, n: int) -> list[tuple[float, float]]:
        d = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        return [
            (
                cb[0] + r * math.cos(a0 + d * i / n),
                cb[1] + r * math.sin(a0 + d * i / n),
            )
            for i in range(n + 1)
        ]

    ang_l = math.atan2(cl[1] - cb[1], cl[0] - cb[0])
    ang_r = math.atan2(cr[1] - cb[1], cr[0] - cb[0])
    blade_pts = [BLADE_TIP, cl] + arc(ang_l, ang_r, 28)[1:] + [cr]

    # teardrop: tangents from HAIR_TIP to the inward-offset circle; the dome
    # is the arc facing the ferrule, so the white crescent stays parallel
    rh = r - HAIR_GAP
    px, py = HAIR_TIP[0] - cb[0], HAIR_TIP[1] - cb[1]
    dp = math.hypot(px, py)
    phi = math.atan2(py, px)
    alpha = math.acos(min(1.0, rh / dp))
    t1, t2 = phi + alpha, phi - alpha
    a_target = math.atan2(base[1] - cb[1], base[0] - cb[0])
    span_ccw = (t2 - t1) % (2 * math.pi)
    if ((a_target - t1) % (2 * math.pi)) <= span_ccw:
        dome = [t1 + span_ccw * i / 48 for i in range(49)]
    else:
        dome = [t1 - (2 * math.pi - span_ccw) * i / 48 for i in range(49)]
    hair_pts = [
        (cb[0] + rh * math.cos(t), cb[1] + rh * math.sin(t)) for t in dome
    ] + [HAIR_TIP]

    def poly(pts: list[tuple[float, float]]) -> str:
        return "M" + "L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + "Z"

    return poly(blade_pts), poly(hair_pts)


def build_svg() -> str:
    blade, hair = blade_and_hair()
    sweep_tr = (
        f"translate({SWEEP_AT[0]} {SWEEP_AT[1]}) rotate({SWEEP_TILT}) "
        f"scale({SWEEP_SCALE}) translate({-SWEEP_CX} {-SWEEP_CY})"
    )
    group = f"translate(512 512) scale({GROUP_SCALE}) translate(-512 -512)"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="0" y="0" width="1024" height="1024" rx="{TILE_R}" fill="{PAPER}"/>
  <g transform="{group}">
    <g transform="{sweep_tr}">
      <path d="{SWEEP}" fill="{INK}"/>
    </g>
    <path d="{blade}" fill="{INK}"/>
    <path d="{hair}" fill="{INK}"/>
  </g>
</svg>
'''


def render_master() -> Image.Image:
    png = resvg_py.svg_to_bytes(
        svg_string=build_svg(), width=RENDER_PX, height=RENDER_PX
    )
    return (
        Image.open(io.BytesIO(png)).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    )


def write_asset_contents() -> None:
    """Writes both Contents.json files.

    The icon set pairs every point size with 1x and 2x. `scale` is mandatory in
    each entry: omit it and actool reports all ten children as unassigned and
    silently emits no Assets.car, so the app ships with no icon at all.
    """
    ASSETS.mkdir(parents=True, exist_ok=True)
    (ASSETS / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            images.append(
                {
                    "idiom": "mac",
                    "size": f"{points}x{points}",
                    "scale": f"{scale}x",
                    "filename": f"icon_{points}x{points}{suffix}.png",
                }
            )
    (ICONSET / "Contents.json").write_text(
        json.dumps(
            {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2
        )
        + "\n"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--preview",
        type=str,
        default="",
        help="also write the 1024 master to this path",
    )
    args = ap.parse_args()

    ICONSET.mkdir(parents=True, exist_ok=True)
    write_asset_contents()
    master = render_master()
    for name, s in SIZES.items():
        img = master if s == 1024 else master.resize((s, s), Image.LANCZOS)
        img.save(ICONSET / name)
    if args.preview:
        master.save(args.preview)
    print(
        f"wrote {len(SIZES)} sizes to {ICONSET}"
        + (f", preview {args.preview}" if args.preview else "")
    )


if __name__ == "__main__":
    sys.exit(main())
