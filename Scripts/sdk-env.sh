# Source (don't exec) after versions.env: pins every local build to the macOS SDK in MACOS_SDK_VERSION.
# Exports SDKROOT so swift/clang/cmake/meson/xcrun all compile against that SDK, not whatever the selected
# developer dir happens to default to. Fails loudly if the pinned SDK isn't installed.
_sdk="$(xcrun --sdk "macosx${MACOS_SDK_VERSION:?versions.env not sourced}" --show-sdk-path 2>/dev/null || true)"
if [ -z "$_sdk" ]; then
  echo "ERROR: macOS ${MACOS_SDK_VERSION} SDK not found (developer dir: $(xcode-select -p 2>/dev/null || echo '?'))." >&2
  echo "       Install Xcode ${XCODE_VERSION} (or its Command Line Tools), then:" >&2
  echo "         sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi
export SDKROOT="$_sdk"
unset _sdk
echo "==> SDK: $SDKROOT"
