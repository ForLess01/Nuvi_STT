#!/usr/bin/env bash
# Regenerates Resources/Nuvi.icns from the official Nuvi isologo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/generate-brand-assets.py
swift scripts/make-icon.swift
iconutil -c icns build/Nuvi.iconset -o Resources/Nuvi.icns
echo "==> Wrote Resources/Nuvi.icns"
