#!/bin/zsh
# Builds the app and opens it, passing any arguments on (for example a picture to show).
set -euo pipefail
ROOT=${0:A:h:h}
"$ROOT/Scripts/build-app.sh"
exec "${PIXIX_CACHE:-$HOME/Library/Caches/Pixix}/dist/Pixix.app/Contents/MacOS/Pixix" "$@"
