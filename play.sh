#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
cd "$ROOT_DIR"

APP_BUNDLE="$ROOT_DIR/build/RunnerMetal.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/RunnerMetal"

if [[ ! -x "$APP_BIN" ]]; then
  echo "Building RunnerMetal.app (native Metal, Release/Ninja)..."
  cmake -B build -G Ninja -DENABLE_MOLTENVK_ORACLE=OFF
  ninja -C build RunnerMetal
fi

export ME_PC_LOG_PATH="${ME_PC_LOG_PATH:-$ROOT_DIR/work/pc-runtime.log}"
export ME_PC_FULLSCREEN="${ME_PC_FULLSCREEN:-1}"

# Launch through LaunchServices (`open -n -W -a`) so macOS Game Mode (gamepolicyd)
# recognizes RunnerMetal.app via Info.plist (LSSupportsGameMode / LSApplicationCategoryType).
env_args=()
for var in ${(k)parameters[(R)*export*]}; do
  case "$var" in
    ME_PC_*|MTL_*|SDL_*|PXSHIM_*)
      env_args+=(--env "${var}=${(P)var}")
      ;;
  esac
done

exec open -n -W -a "$APP_BUNDLE" "${env_args[@]}" --args \
  "$ROOT_DIR/work/game_data/Binaries" \
  "$ROOT_DIR/work/pc-deps" \
  "$ROOT_DIR/work/pc-user" \
  "$@"
