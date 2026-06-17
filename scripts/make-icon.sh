#!/usr/bin/env bash
# Regenerates Resources/Nuvi.icns from the ferrofluid icon generator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift scripts/make-icon.swift
iconutil -c icns build/Nuvi.iconset -o Resources/Nuvi.icns
echo "==> Wrote Resources/Nuvi.icns"
