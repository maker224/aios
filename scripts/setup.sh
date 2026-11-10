#!/usr/bin/env bash
# Sets up the AIoS Flutter project.
# Run after installing Flutter: https://docs.flutter.dev/get-started/install
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is not installed."
  echo "Install it first: https://docs.flutter.dev/get-started/install"
  exit 1
fi

echo "==> Generating platform scaffolding (android, ios, macos, windows)..."
flutter create \
  --org dev.aios \
  --project-name aios \
  --platforms=android,ios,macos,windows \
  .

echo "==> Applying platform permissions..."
python3 scripts/apply_permissions.py

echo "==> Fetching dependencies..."
flutter pub get

echo ""
echo "Done! Run the app with one of:"
echo "  flutter run -d macos"
echo "  flutter run -d ios      # (needs Xcode + a device/simulator)"
echo "  flutter run -d android  # (needs Android Studio + device/emulator)"
echo "  flutter run -d windows"
echo ""
echo "Tip: run 'flutter doctor' first to check your toolchain."
