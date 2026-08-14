#!/usr/bin/env python3
"""Derive runtime SVG assets from the official Nuvi logo geometry.

The source SVG remains untouched. Only its vector paths are reused; colors are
normalized to the approved Nuvi palette so generated assets cannot drift.
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Resources" / "Nuvi_Logo.svg"
OUTPUT = ROOT / "Sources" / "Nuvi" / "Presentation" / "Brand" / "Assets"

SOFT_WHITE = "#F4F5F7"
CHARCOAL = "#0F1116"
LAVENDER = "#B89BFF"


def paths(svg: str) -> list[str]:
    return [
        match.group(1)
        for element in re.findall(r"<path\b[^>]*>", svg)
        if (match := re.search(r'd="([^"]+)"', element))
    ]


def symbol_svg(path_data: list[str], foreground: str) -> str:
    outer, hole, dot = path_data[1], path_data[2], path_data[7]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="145 463 315 300">
  <path d="{outer} {hole}" fill="{foreground}" fill-rule="evenodd"/>
  <path d="{dot}" fill="{LAVENDER}"/>
</svg>
'''


def wordmark_svg(path_data: list[str]) -> str:
    outer, hole = path_data[1], path_data[2]
    letters = "\n  ".join(
        f'<path d="{path_data[index]}" fill="{SOFT_WHITE}"/>'
        for index in range(3, 7)
    )
    dots = "\n  ".join(
        f'<path d="{path_data[index]}" fill="{LAVENDER}"/>'
        for index in (7, 8)
    )
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="145 463 970 300">
  <path d="{outer} {hole}" fill="{SOFT_WHITE}" fill-rule="evenodd"/>
  {letters}
  {dots}
</svg>
'''


def main() -> None:
    path_data = paths(SOURCE.read_text())
    if len(path_data) != 9:
        raise SystemExit(f"Expected 9 paths in {SOURCE}, found {len(path_data)}")

    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "NuviIsologoDark.svg").write_text(symbol_svg(path_data, SOFT_WHITE))
    (OUTPUT / "NuviIsologoLight.svg").write_text(symbol_svg(path_data, CHARCOAL))
    (OUTPUT / "NuviWordmarkDark.svg").write_text(wordmark_svg(path_data))
    print(f"Generated official Nuvi brand assets in {OUTPUT}")


if __name__ == "__main__":
    main()
