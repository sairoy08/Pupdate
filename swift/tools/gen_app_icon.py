"""App icon: the calm puppy on the night sky. Renders with headless Chrome.
  python3 gen_app_icon.py     (writes Pupdate/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png)
"""
import subprocess
import tempfile
from pathlib import Path

from dog_preview import dog_svg

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT = Path(__file__).resolve().parents[1] / "Pupdate/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
STARS = [(120, 150, 7), (860, 120, 9), (930, 330, 5), (90, 420, 5), (760, 60, 4), (230, 70, 4)]

stars = "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#f3f4ff" opacity=".8"/>' for x, y, r in STARS)
html = f"""<!doctype html><body style="margin:0;width:1024px;height:1024px;overflow:hidden;
background:radial-gradient(circle at 50% 58%, #2a3478 0%, #141a44 45%, #0a0d1c 100%)">
<svg width="1024" height="1024" style="position:absolute">{stars}
<defs><radialGradient id="glow"><stop offset="0" stop-color="#ffbe3d" stop-opacity=".22"/><stop offset="1" stop-color="#ffbe3d" stop-opacity="0"/></radialGradient></defs>
<circle cx="512" cy="560" r="460" fill="url(#glow)"/></svg>
<div style="position:absolute;left:72px;top:92px">{dog_svg(form="sprout", mood="calm", size=880)}</div>"""

with tempfile.TemporaryDirectory() as d:
    page = Path(d) / "icon.html"
    page.write_text(html)
    subprocess.run([CHROME, "--headless", "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=1024,1024",
                    f"--screenshot={OUT}", page.as_uri()], check=True, capture_output=True)
print("wrote", OUT)
