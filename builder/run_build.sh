#!/bin/bash
set -e

if [ "$LOG_VERBOSE" = "1" ]; then
    set -x
fi

cd /app/source_code

echo "==> STEP: flutter pub get"
echo "Running flutter pub get..."
flutter pub get

if grep -q "build_runner" pubspec.yaml; then
    echo "==> STEP: build_runner"
    echo "⚙️ Found build_runner in pubspec.yaml. Running code generation..."
    flutter pub run build_runner build --delete-conflicting-outputs
fi

if [ -f "scripts/generate.dart" ]; then
    echo "==> STEP: scripts/generate.dart"
    echo "⚙️ Found scripts/generate.dart. Running custom generation script..."
    dart run scripts/generate.dart
fi

echo "==> STEP: Build APK"
echo "Building APK..."
if [ -n "$LANE" ]; then
    echo "==> STEP: Fastlane"
    echo "🚀 Running Fastlane lane: $LANE for Android..."
    cd android
    fastlane "$LANE"
    cd ..
else
    flutter build apk --release
fi

echo "==> STEP: Collect artifact"
echo "Build successful! Locating APK..."
APK_PATH=$(find build/app/outputs -name "*-release.apk" | head -n 1)

if [ -n "$APK_PATH" ]; then
    echo "Found APK at: $APK_PATH"
    cp "$APK_PATH" /output/app-release.apk
    echo "Saved to /output/app-release.apk"
else
    echo "Error: No release APK found!"
    exit 1
fi
