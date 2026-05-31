#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dpkg-buildpackage -b -uc -us
echo "Build complete. Check parent directory for .deb"
