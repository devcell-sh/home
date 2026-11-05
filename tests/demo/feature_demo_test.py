# /// script
# requires-python = ">=3.11"
# dependencies = ["patchright"]
# ///
"""Visual feature demo: screenshots proving desktop, stealth browser, and GUI capabilities."""

import glob
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from patchright.sync_api import sync_playwright

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_BASE = REPO_ROOT / "tests" / "results"
DOCS_IMG_DIR = REPO_ROOT / "docs" / "images"

STEALTH_ARGS = [
    "--no-sandbox",
    "--use-gl=angle",
    "--use-angle=vulkan",
    "--ignore-gpu-blocklist",
    "--force-device-scale-factor=1",
    "--disable-features=AudioServiceSandbox",
    "--disable-blink-features=AutomationControlled",
]

SVG_LOGO = """\
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" width="400" height="400">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#0a0e27"/>
      <stop offset="100%" stop-color="#1a1e3e"/>
    </linearGradient>
    <linearGradient id="glow" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#4fc3f7" stop-opacity="0.9"/>
      <stop offset="100%" stop-color="#29b6f6" stop-opacity="0.4"/>
    </linearGradient>
    <filter id="blur"><feGaussianBlur stdDeviation="3"/></filter>
  </defs>
  <rect width="400" height="400" rx="32" fill="url(#bg)"/>
  <text x="60" y="260" font-family="monospace" font-size="200" font-weight="bold"
        fill="none" stroke="#ffffff" stroke-width="3" opacity="0.3">[</text>
  <text x="270" y="260" font-family="monospace" font-size="200" font-weight="bold"
        fill="none" stroke="#ffffff" stroke-width="3" opacity="0.3">]</text>
  <g transform="translate(200,180)">
    <ellipse cx="0" cy="20" rx="55" ry="15" fill="#4fc3f7" opacity="0.15" filter="url(#blur)"/>
    <path d="M-45,20 C-45,-40 -30,-65 0,-65 C30,-65 45,-40 45,20
             L45,50 Q35,40 30,50 Q25,40 20,50 Q15,40 10,50
             Q5,40 0,50 Q-5,40 -10,50 Q-15,40 -20,50
             Q-25,40 -30,50 Q-35,40 -40,50 L-45,20 Z"
          fill="url(#glow)"/>
    <ellipse cx="-15" cy="-15" rx="10" ry="12" fill="#0a0e27"/>
    <ellipse cx="15" cy="-15" rx="10" ry="12" fill="#0a0e27"/>
    <ellipse cx="-13" cy="-18" rx="4" ry="5" fill="#ffffff" opacity="0.8"/>
    <ellipse cx="17" cy="-18" rx="4" ry="5" fill="#ffffff" opacity="0.8"/>
  </g>
  <text x="200" y="320" text-anchor="middle" font-family="monospace"
        font-size="22" font-weight="bold" fill="#4fc3f7" letter-spacing="2">
    GHOSTS IN THE CELL
  </text>
  <text x="200" y="348" text-anchor="middle" font-family="monospace"
        font-size="12" fill="#ffffff" opacity="0.4">
    a devcell story
  </text>
</svg>"""


def resolve_stealth_env() -> dict[str, str]:
    """Extract LD_LIBRARY_PATH, VK_ICD, and chromium path from patchright-mcp-cell wrapper."""
    wrapper = shutil.which("patchright-mcp-cell")
    if not wrapper:
        return {}
    real = os.path.realpath(wrapper)
    script = f"""
set -e
eval "$(grep '^export ' '{real}' | head -5)"
eval "$(grep '_CHROMIUM_X86=' '{real}' | grep -v '#' | head -1)"
printf 'LD_LIBRARY_PATH=%s\\n' "$LD_LIBRARY_PATH"
printf 'VK_ICD_FILENAMES=%s\\n' "$VK_ICD_FILENAMES"
printf 'PLAYWRIGHT_BROWSERS_PATH=%s\\n' "$PLAYWRIGHT_BROWSERS_PATH"
printf '_CHROMIUM_X86=%s\\n' "$_CHROMIUM_X86"
# Extract the x86_64 VK_ICD path that the wrapper uses when running x86 chromium
_X86_VK=$(grep 'lvp_icd.x86_64' '{real}' | grep -oP '"[^"]+"' | head -1 | tr -d '"')
printf 'VK_ICD_FILENAMES_X86=%s\\n' "$_X86_VK"
"""
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=5)
    env = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if v:
                env[k] = v
    return env


def desktop_screenshot(path: Path) -> bool:
    return subprocess.run(
        ["import", "-window", "root", str(path)], capture_output=True, timeout=10
    ).returncode == 0


def xdt(*args: str) -> str:
    r = subprocess.run(["xdotool", *args], capture_output=True, text=True, timeout=10)
    return r.stdout.strip()


def wmctrl(*args: str):
    subprocess.run(["wmctrl", *args], capture_output=True, timeout=10)


def require(*cmds: str):
    missing = [c for c in cmds if not shutil.which(c)]
    if missing:
        print(f"SKIP: {', '.join(missing)} not found")
        sys.exit(0)


def generate_kicad_schematic(outdir: Path) -> bool:
    """Generate Arduino LED schematic with embedded KiCad symbols."""
    candidates = glob.glob("/nix/store/*/share/kicad/symbols/Device.kicad_sym")
    symdir = None
    for c in candidates:
        with open(c) as f:
            if '"9.0"' in f.read(200):
                symdir = os.path.dirname(c)
                break
    if not symdir:
        symdir = os.path.dirname(candidates[0]) if candidates else None
    if not symdir:
        return False

    def extract_symbol(filepath, name):
        with open(filepath) as f:
            content = f.read()
        target = f'(symbol "{name}"'
        idx = content.find(target)
        if idx == -1:
            return None
        depth, i = 0, idx
        while i < len(content):
            if content[i] == "(":
                depth += 1
            elif content[i] == ")":
                depth -= 1
                if depth == 0:
                    return content[idx : i + 1]
            i += 1
        return None

    syms = {
        ("MCU_Module", "Arduino_Nano_v2.x"): f"{symdir}/MCU_Module.kicad_sym",
        ("Device", "R"): f"{symdir}/Device.kicad_sym",
        ("Device", "LED"): f"{symdir}/Device.kicad_sym",
        ("power", "GND"): f"{symdir}/power.kicad_sym",
        ("power", "+5V"): f"{symdir}/power.kicad_sym",
    }
    lib_parts = []
    for (lib, name), path in syms.items():
        s = extract_symbol(path, name)
        if not s:
            return False
        lib_parts.append(s.replace(f'(symbol "{name}"', f'(symbol "{lib}:{name}"', 1))

    sch = (
        '(kicad_sch\n  (version 20241209)\n  (generator "devcell-demo")\n'
        '  (generator_version "9.0")\n  (uuid "a1b2c3d4-e5f6-7890-abcd-ef0123456789")\n'
        '  (paper "A4")\n  (title_block\n    (title "Arduino LED Blink")\n'
        '    (comment 1 "devcell demo circuit")\n  )\n  (lib_symbols\n    '
        + "\n    ".join(lib_parts)
        + "\n  )\n"
        + '  (symbol\n    (lib_id "MCU_Module:Arduino_Nano_v2.x")\n    (at 160.02 96.52 0)\n    (unit 1)\n'
        + "    (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no)\n"
        + '    (uuid "11111111-1111-1111-1111-111111111111")\n'
        + '    (property "Reference" "U1" (at 149.86 73.025 0)\n      (effects (font (size 1.27 1.27)) (justify left bottom)))\n'
        + '    (property "Value" "Arduino_Nano_v2.x" (at 165.1 72.39 0)\n      (effects (font (size 1.27 1.27)) (justify left top)))\n'
        + '    (property "Footprint" "" (at 160.02 96.52 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Datasheet" "" (at 160.02 96.52 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n  )\n'
        + '  (symbol\n    (lib_id "Device:R")\n    (at 139.7 78.74 90)\n    (unit 1)\n'
        + "    (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no)\n"
        + '    (uuid "22222222-2222-2222-2222-222222222222")\n'
        + '    (property "Reference" "R1" (at 139.7 75.565 0)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Value" "220" (at 139.7 82.55 0)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Footprint" "" (at 139.7 78.74 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Datasheet" "" (at 139.7 78.74 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n  )\n'
        + '  (symbol\n    (lib_id "Device:LED")\n    (at 128.27 78.74 0)\n    (unit 1)\n'
        + "    (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no)\n"
        + '    (uuid "33333333-3333-3333-3333-333333333333")\n'
        + '    (property "Reference" "D1" (at 128.27 72.39 0)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Value" "LED" (at 128.27 85.09 0)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Footprint" "" (at 128.27 78.74 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Datasheet" "" (at 128.27 78.74 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n  )\n'
        + '  (symbol\n    (lib_id "power:GND")\n    (at 124.46 86.36 0)\n    (unit 1)\n'
        + "    (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no)\n"
        + '    (uuid "44444444-4444-4444-4444-444444444444")\n'
        + '    (property "Reference" "#PWR01" (at 124.46 92.71 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Value" "GND" (at 124.46 90.17 0)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Footprint" "" (at 124.46 86.36 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Datasheet" "" (at 124.46 86.36 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n  )\n'
        + '  (symbol\n    (lib_id "power:+5V")\n    (at 165.1 121.92 0)\n    (unit 1)\n'
        + "    (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no)\n"
        + '    (uuid "55555555-5555-5555-5555-555555555555")\n'
        + '    (property "Reference" "#PWR02" (at 165.1 125.73 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Value" "+5V" (at 165.1 118.11 0)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Footprint" "" (at 165.1 121.92 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n'
        + '    (property "Datasheet" "" (at 165.1 121.92 0) (hide yes)\n      (effects (font (size 1.27 1.27))))\n  )\n'
        + '  (wire (pts (xy 147.32 78.74) (xy 143.51 78.74))\n    (stroke (width 0) (type default))\n    (uuid "aaaa1111-1111-1111-1111-111111111111"))\n'
        + '  (wire (pts (xy 135.89 78.74) (xy 132.08 78.74))\n    (stroke (width 0) (type default))\n    (uuid "aaaa2222-2222-2222-2222-222222222222"))\n'
        + '  (wire (pts (xy 124.46 78.74) (xy 124.46 86.36))\n    (stroke (width 0) (type default))\n    (uuid "aaaa3333-3333-3333-3333-333333333333"))\n)'
    )
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "arduino-led.kicad_sch").write_text(sch)
    (outdir / "arduino-led.kicad_pro").write_text(
        '{"board":{"design_settings":{}},"meta":{"filename":"arduino-led.kicad_pro","version":1},'
        '"schematic":{"drawing":{},"meta":{"version":1}}}'
    )
    print(f"  generated schematic with {len(lib_parts)} embedded symbols")
    return True


class Demo:
    def __init__(self):
        now = datetime.now(timezone.utc)
        self.run_id = f"{now.strftime('%Y-%m-%dT%H%M%SZ')}-feature-demo"
        self.results_dir = RESULTS_BASE / self.run_id
        self.ss_dir = self.results_dir / "screenshots"
        self.ss_dir.mkdir(parents=True, exist_ok=True)
        DOCS_IMG_DIR.mkdir(parents=True, exist_ok=True)
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.env = resolve_stealth_env()
        self.tmpdir = Path(tempfile.mkdtemp())
        self._procs: list[subprocess.Popen] = []

    def _assert(self, name: str, passed: bool, detail: str = ""):
        if passed:
            print(f"  ✓ assert: {name}")
        else:
            print(f"  ✗ assert: {name}{': ' + detail if detail else ''}")
            self.failed += 1

    def _screenshot(self, name: str) -> bool:
        path = self.ss_dir / name
        if desktop_screenshot(path):
            shutil.copy2(path, DOCS_IMG_DIR / name)
            print(f"  ✓ screenshot: {name}")
            self.passed += 1
            return True
        print(f"  ✗ screenshot failed: {name}")
        self.failed += 1
        return False

    def _tile_window(self, title: str, x: int, y: int, w: int, h: int):
        """Find a window by title substring and position it."""
        wid = xdt("search", "--onlyvisible", "--name", title)
        if not wid:
            return
        wid = wid.split("\n")[0]
        xdt("windowactivate", "--sync", wid)
        wmctrl("-i", "-r", wid, "-b", "remove,maximized_vert,maximized_horz")
        time.sleep(0.3)
        xdt("windowsize", "--sync", wid, str(w), str(h))
        xdt("windowmove", "--sync", wid, str(x), str(y))

    def _apply_env(self):
        for k in ("LD_LIBRARY_PATH", "VK_ICD_FILENAMES", "PLAYWRIGHT_BROWSERS_PATH"):
            if k in self.env:
                os.environ[k] = self.env[k]
        # When using x86 chromium, switch to the x86_64 Vulkan ICD so WebGL works
        chromium_path = self.env.get("_CHROMIUM_X86")
        x86_vk = self.env.get("VK_ICD_FILENAMES_X86")
        if chromium_path and os.path.exists(chromium_path) and x86_vk and os.path.exists(x86_vk):
            os.environ["VK_ICD_FILENAMES"] = x86_vk
            print(f"  using x86 chromium: {chromium_path}")
            print(f"  using x86_64 VK ICD: {x86_vk}")

    def _cleanup(self):
        for p in self._procs:
            try:
                p.terminate()
                p.wait(timeout=5)
            except Exception:
                p.kill()
        self._procs.clear()
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # ── Phase 1 ────────────────────────────────────────────────────
    def phase_desktop(self):
        print("Phase 1: empty desktop")
        for name in ["chromium", "firefox", "inkscape", "eeschema"]:
            subprocess.run(["pkill", "-f", name], capture_output=True)
        time.sleep(2)

        wmctrl("-s", "0")
        wmctrl("-n", "1")
        xdt("set_desktop_viewport", "0", "0")
        subprocess.run(
            ["xprop", "-root", "-f", "_NET_DESKTOP_NAMES", "8u",
             "-set", "_NET_DESKTOP_NAMES", "devcell"],
            capture_output=True,
        )

        devcell_home = os.environ.get("DEVCELL_HOME", "/opt/devcell")
        template = Path(devcell_home) / ".icewm" / "wallpaper-template.svg"
        if template.exists():
            subprocess.run(
                f"sed 's|{{{{CELL_ID}}}}|devcell|g' '{template}'"
                " | rsvg-convert -w 1920 -h 1080 -o /tmp/wallpaper-live.png",
                shell=True, capture_output=True,
            )
            subprocess.run(["feh", "--bg-fill", "/tmp/wallpaper-live.png"], capture_output=True)
            time.sleep(0.5)

        time.sleep(1)
        self._screenshot("demo-1-desktop.png")

    # ── Phase 2 ────────────────────────────────────────────────────
    def phase_stealth(self):
        print("Phase 2: stealth browser (3 detection sites)")
        self._apply_env()

        chromium_path = self.env.get("_CHROMIUM_X86")
        launch_kw: dict = {"headless": False, "args": list(STEALTH_ARGS)}
        if chromium_path and os.path.exists(chromium_path):
            launch_kw["executable_path"] = chromium_path

        with sync_playwright() as pw:
            # -- screenshot 1: CreepJS (left) + SannyBot (right) --
            b_left = pw.chromium.launch(**launch_kw)
            b_right = pw.chromium.launch(**launch_kw)

            pg_creep = b_left.new_page()
            pg_sanny = b_right.new_page()

            print("  loading creepjs + sannybot...")
            pg_creep.goto("https://abrahamjuliot.github.io/creepjs/", wait_until="domcontentloaded")
            pg_sanny.goto("https://bot.sannysoft.com/", wait_until="domcontentloaded")

            print("  waiting for detection results...")
            time.sleep(25)

            # Assert: SannyBot has no red cells (detect by computed background-color)
            red_cells = pg_sanny.evaluate("""(() => {
                const reds = [];
                for (const td of document.querySelectorAll('td')) {
                    const bg = getComputedStyle(td).backgroundColor;
                    const m = bg.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);
                    if (!m) continue;
                    const r = +m[1], g = +m[2], b = +m[3];
                    if (r > 200 && g < 100 && b < 100) reds.push(td.textContent.trim());
                }
                return reds;
            })()""")
            self._assert(
                "sannybot: no red cells",
                len(red_cells) == 0,
                f"red cells: {red_cells}",
            )

            # Assert: CreepJS GPU is not "unsupported"
            gpu_status = pg_creep.evaluate("""(() => {
                const text = document.body.innerText;
                const m = text.match(/gpu:[\\s\\S]*?\\n\\s*(.+)/i);
                return m ? m[1].trim() : '';
            })()""")
            self._assert(
                "creepjs: gpu supported",
                gpu_status.lower() != "unsupported" and gpu_status != "",
                f"gpu shows: {gpu_status}",
            )

            # tile windows by title: CreepJS left, SannyBot right
            self._tile_window("CreepJS", 0, 0, 960, 1080)
            self._tile_window("Antibot", 960, 0, 960, 1080)
            time.sleep(1)

            # scroll creepjs to show detection cards
            pg_creep.evaluate("window.scrollBy(0, 600)")
            time.sleep(1)

            self._screenshot("demo-2-stealth-1.png")

            b_left.close()
            b_right.close()
            time.sleep(1)

            # -- screenshot 2: Pixelscan --
            print("  loading pixelscan...")
            b_px = pw.chromium.launch(**launch_kw)
            pg_px = b_px.new_page()
            pg_px.goto("https://pixelscan.net/bot-check", wait_until="domcontentloaded")

            print("  waiting for pixelscan verdict...")
            time.sleep(15)

            # maximize the only chromium window on screen
            wid = xdt("search", "--onlyvisible", "--class", "Chromium")
            if wid:
                wid = wid.split("\n")[0]
                wmctrl("-i", "-r", wid, "-b", "add,maximized_vert,maximized_horz")
            time.sleep(1)

            self._screenshot("demo-2-stealth-2.png")
            b_px.close()

    # ── Phase 3 ────────────────────────────────────────────────────
    def phase_inkscape(self):
        print("Phase 3: SVG logo in Inkscape")
        if not shutil.which("inkscape"):
            print("  SKIP: inkscape not found")
            self.skipped += 1
            return

        svg_file = self.tmpdir / "ghosts-in-the-cell.svg"
        svg_file.write_text(SVG_LOGO)
        shutil.copy2(svg_file, self.results_dir / "ghosts-in-the-cell.svg")

        proc = subprocess.Popen(
            ["inkscape", str(svg_file)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self._procs.append(proc)

        print("  waiting for Inkscape...")
        time.sleep(8)

        wid = xdt("search", "--onlyvisible", "--name", "ghosts")
        if not wid:
            wid = xdt("search", "--onlyvisible", "--class", "Inkscape")
        wid = wid.split("\n")[0] if wid else ""

        if wid:
            wmctrl("-i", "-r", wid, "-b", "remove,maximized_vert,maximized_horz")
            time.sleep(0.5)
            xdt("windowsize", "--sync", wid, "1100", "700")
            xdt("windowmove", "--sync", wid, "320", "50")
            time.sleep(2)
            self._screenshot("demo-3-inkscape.png")
        else:
            print("  ✗ Inkscape window not found")
            self.failed += 1

        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    # ── Phase 4 ────────────────────────────────────────────────────
    def phase_kicad(self):
        print("Phase 4: KiCad schematic editor")
        if not shutil.which("eeschema"):
            print("  SKIP: eeschema not found")
            self.skipped += 1
            return

        kicad_dir = self.tmpdir / "kicad"
        if not generate_kicad_schematic(kicad_dir):
            print("  SKIP: failed to generate schematic")
            self.skipped += 1
            return

        for lck in kicad_dir.glob("~*.lck"):
            lck.unlink(missing_ok=True)

        proc = subprocess.Popen(
            ["eeschema", str(kicad_dir / "arduino-led.kicad_sch")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self._procs.append(proc)

        print("  waiting for eeschema...")
        kicad_win = ""
        for _ in range(10):
            time.sleep(2)
            # dismiss info/warning dialogs
            for dialog in ("Information", "Warning", "Error", "File Open"):
                dwid = xdt("search", "--onlyvisible", "--name", dialog)
                if dwid:
                    xdt("key", "--window", dwid.split("\n")[0], "Return")

            r = subprocess.run(
                ["wmctrl", "-l"], capture_output=True, text=True, timeout=5,
            )
            for line in r.stdout.splitlines():
                low = line.lower()
                if ("arduino" in low or "schematic" in low) and not any(
                    x in low for x in ("setup", "error", "no schematic")
                ):
                    kicad_win = line.split()[0]
                    break
            if kicad_win:
                break

        if kicad_win:
            wmctrl("-i", "-r", kicad_win, "-b", "remove,maximized_vert,maximized_horz")
            time.sleep(0.5)
            xdt("windowsize", "--sync", kicad_win, "1100", "700")
            xdt("windowmove", "--sync", kicad_win, "320", "50")
            time.sleep(1)
            xdt("key", "--window", kicad_win, "ctrl+Home")
            time.sleep(1)
            self._screenshot("demo-4-kicad.png")
        else:
            print("  ✗ eeschema window not found")
            self.failed += 1

        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    # ── orchestrator ───────────────────────────────────────────────
    def run(self) -> bool:
        print(f"Run: {self.run_id}")
        print(f"Results: {self.results_dir}")

        try:
            self.phase_desktop()
            self.phase_stealth()
            self.phase_inkscape()
            self.phase_kicad()
        finally:
            self._cleanup()

        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (self.results_dir / "summary.txt").write_text(
            f"Run:    {self.run_id}\nDate:   {now}\n"
            f"Pass:   {self.passed}\nFail:   {self.failed}\nSkip:   {self.skipped}\n"
            f"Phases: desktop, stealth(creepjs+sannybot), stealth(pixelscan), inkscape, kicad\n"
        )
        print(f"\nFeature demo: Passed={self.passed} Failed={self.failed} Skipped={self.skipped}")
        print(f"Results: {self.results_dir}")
        return self.failed == 0


if __name__ == "__main__":
    os.environ.setdefault("DISPLAY", ":99")
    require("import", "xdotool", "wmctrl", "xprop")
    try:
        xdt("getdisplaygeometry")
    except Exception:
        print(f"SKIP: no display on {os.environ['DISPLAY']}")
        sys.exit(0)
    sys.exit(0 if Demo().run() else 1)
