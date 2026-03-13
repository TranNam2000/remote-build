#!/bin/bash
set -e

REPO_URL=$1
BRANCH=$2
BUILD_ID=${3:-"ios_$(date +%s)"}
LANE=${4:-${FASTLANE_LANE:-"beta"}}
WORK_DIR="/tmp/flutter_build_$BUILD_ID"
OUTPUT_DIR="${PWD}/completed_builds/$BUILD_ID"

echo "Starting Local macOS iOS Build..."
echo "Cloning repository..."

mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

cd "$WORK_DIR"
if [ -n "$BRANCH" ]; then
    echo "Cloning branch: $BRANCH"
    git clone --branch "$BRANCH" "$REPO_URL" source_code
else
    git clone "$REPO_URL" source_code
fi
cd source_code

if [ -f ".env" ]; then
    echo "Loading .env from repository..."
    set -a
    . ./.env
    set +a
fi

if ! command -v fastlane >/dev/null 2>&1; then
    echo "Fastlane not found. Installing..."
    if command -v gem >/dev/null 2>&1; then
        gem install fastlane --no-document
    else
        echo "Error: RubyGems (gem) not found. Please install Ruby and RubyGems."
        exit 1
    fi
fi

echo "Running flutter pub get..."
if [ "$SKIP_PUB_GET_IF_CACHED" = "1" ] && [ -f ".dart_tool/package_config.json" ] && [ -f "pubspec.lock" ]; then
    echo "Skipping flutter pub get (cache present)."
else
    flutter pub get
fi

if grep -q "build_runner" pubspec.yaml; then
    if [ "$SKIP_BUILD_RUNNER_IF_CLEAN" = "1" ] && [ -d ".dart_tool/build" ]; then
        echo "Skipping build_runner (cache present)."
    else
        echo "⚙️ Found build_runner in pubspec.yaml. Running code generation..."
        flutter pub run build_runner build --delete-conflicting-outputs
    fi
fi

if [ -f "scripts/generate.dart" ]; then
    echo "⚙️ Found scripts/generate.dart. Running custom generation script..."
    dart run scripts/generate.dart
fi

echo "Building iOS with Fastlane..."
FASTFILE_PATH=""
FASTFILE_MANAGED=0
if [ -f "ios/fastlane/Fastfile" ]; then
    FASTFILE_PATH="ios/fastlane/Fastfile"
elif [ -f "ios/Fastfile" ]; then
    FASTFILE_PATH="ios/Fastfile"
fi

if [ -n "$FASTFILE_PATH" ] && grep -q "Codex managed Fastfile" "$FASTFILE_PATH"; then
    FASTFILE_MANAGED=1
fi

if [ -z "$FASTFILE_PATH" ] || [ "$FASTFILE_MANAGED" = "1" ]; then
    echo "Generating a default Fastlane configuration..."
    mkdir -p ios/fastlane
    cat > ios/fastlane/Fastfile <<'EOF'
# Codex managed Fastfile
default_platform(:ios)

platform :ios do
  desc "Build and upload to TestFlight"
  lane :beta do
    build_args = {
      workspace: "Runner.xcworkspace",
      scheme: "Runner",
      export_method: "app-store",
      skip_package_ipa: true,
      archive_path: ENV["ARCHIVE_PATH"] || "../build/ios/Runner.xcarchive"
    }
    if ENV["FASTLANE_DERIVED_DATA_PATH"] && !ENV["FASTLANE_DERIVED_DATA_PATH"].empty?
      build_args[:derived_data_path] = ENV["FASTLANE_DERIVED_DATA_PATH"]
    end

    build_app(**build_args)

    if ENV["SKIP_TESTFLIGHT"] == "1"
      UI.important("Skipping TestFlight upload: API key info not configured.")
    else
      api_key = app_store_connect_api_key(
        key_id: ENV["ASC_KEY_ID"],
        issuer_id: ENV["ASC_ISSUER_ID"],
        key_filepath: ENV["ASC_KEY_PATH"],
        in_house: false
      )

      upload_to_testflight(
        api_key: api_key,
        app_identifier: ENV["APP_IDENTIFIER"],
        skip_waiting_for_build_processing: true
      )
    end
  end
end
EOF
    FASTFILE_PATH="ios/fastlane/Fastfile"
fi

APP_IDENTIFIER=$(grep -m 1 "PRODUCT_BUNDLE_IDENTIFIER" ios/Runner.xcodeproj/project.pbxproj | sed -E 's/.*= (.*);/\1/' | tr -d '"')
if [ -n "$APP_IDENTIFIER" ]; then
    export APP_IDENTIFIER
    echo "Detected bundle id: $APP_IDENTIFIER"
else
    echo "Warning: Could not detect bundle id from project.pbxproj"
fi

if [ -z "$ASC_KEY_PATH" ]; then
    if command -v find >/dev/null 2>&1; then
        ASC_KEY_PATH=$(find "$HOME" "/Users/mmaac/remote build" -maxdepth 4 -type f -name "AuthKey_*.p8" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1)
    fi
fi

if [ -n "$ASC_KEY_PATH" ] && [ -z "$ASC_KEY_ID" ]; then
    ASC_KEY_ID=$(basename "$ASC_KEY_PATH" | sed -E 's/^AuthKey_([A-Z0-9]+)\.p8$/\1/')
fi

if [ -z "$ASC_KEY_PATH" ] || [ -z "$ASC_ISSUER_ID" ] || [ -z "$ASC_KEY_ID" ]; then
    echo "Warning: Missing App Store Connect API key info."
    echo "TestFlight upload will be skipped. Set ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID to enable upload."
    export SKIP_TESTFLIGHT=1
else
    export ASC_KEY_PATH
    export ASC_KEY_ID
    export ASC_ISSUER_ID
fi

if [ "$CACHE_DERIVED_DATA" = "1" ]; then
    export DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/flutter_derived_data}"
    export FASTLANE_DERIVED_DATA_PATH="$DERIVED_DATA_PATH"
    echo "Using DerivedData cache at: $DERIVED_DATA_PATH"
fi

export ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_DIR/source_code/build/ios/Runner.xcarchive}"

if [ "$CACHE_PODS" = "1" ]; then
    export COCOAPODS_CACHE_PATH="${COCOAPODS_CACHE_PATH:-$HOME/.cocoapods-cache}"
    echo "Using CocoaPods cache at: $COCOAPODS_CACHE_PATH"
fi

echo "🚀 Running Fastlane lane: $LANE for iOS..."
cd ios
if command -v pod >/dev/null 2>&1; then
    export COCOAPODS_DISABLE_STATS=1
    if [ "$FORCE_POD_REPO_UPDATE" = "1" ]; then
        echo "Updating CocoaPods specs repo (forced)..."
        pod repo update --silent
    elif [ ! -d "$HOME/.cocoapods/repos" ] || [ -z "$(ls -A "$HOME/.cocoapods/repos" 2>/dev/null)" ]; then
        echo "CocoaPods specs repo missing. Updating..."
        pod repo update --silent
    else
        echo "Skipping CocoaPods repo update (already present)."
    fi

    echo "Running pod install..."
    POD_CMD="pod"
    if [ -f "Gemfile" ] && command -v bundle >/dev/null 2>&1; then
        POD_CMD="bundle exec pod"
    fi

    if ! $POD_CMD install; then
        echo "pod install failed. Retrying with repo update..."
        if ! $POD_CMD install --repo-update; then
            echo "pod install --repo-update failed. Trying to update PurchasesHybridCommon pods..."
            $POD_CMD update PurchasesHybridCommon PurchasesHybridCommonUI || true
            if ! $POD_CMD install --repo-update; then
                echo "pod install still failing. Removing Podfile.lock and retrying..."
                rm -f Podfile.lock
                $POD_CMD install --repo-update
            fi
        fi
    fi
fi
if [ -f "Gemfile" ] && command -v bundle >/dev/null 2>&1; then
    if [ "$FASTFILE_PATH" = "ios/Fastfile" ]; then
        bundle exec fastlane --fastfile Fastfile "$LANE"
    else
        bundle exec fastlane "$LANE"
    fi
else
    if [ "$FASTFILE_PATH" = "ios/Fastfile" ]; then
        fastlane --fastfile Fastfile "$LANE"
    else
        fastlane "$LANE"
    fi
fi
cd ..

echo "iOS Build completed. Collecting artifacts..."
IPA_PATH=""
XCARCHIVE_PATH=""
if command -v find >/dev/null 2>&1; then
    IPA_PATH=$(find . -type f -name "*.ipa" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1)
    XCARCHIVE_PATH=$(find . -type d -name "*.xcarchive" -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -n 1)
fi

if [ -n "$ARCHIVE_PATH" ] && [ -d "$ARCHIVE_PATH" ]; then
    XCARCHIVE_PATH="$ARCHIVE_PATH"
fi

if [ -n "$IPA_PATH" ] && [ -f "$IPA_PATH" ]; then
    cp "$IPA_PATH" "$OUTPUT_DIR/Runner.ipa"
    echo "Saved to: $OUTPUT_DIR/Runner.ipa"
elif [ -n "$XCARCHIVE_PATH" ] && [ -d "$XCARCHIVE_PATH" ]; then
    XCARCHIVE_NAME="Runner.xcarchive"
    cp -R "$XCARCHIVE_PATH" "$OUTPUT_DIR/$XCARCHIVE_NAME"
    echo "Saved to: $OUTPUT_DIR/$XCARCHIVE_NAME"
else
    echo "Error: No .ipa or .xcarchive found after Fastlane build!"
    exit 1
fi

echo "Saved output to: $OUTPUT_DIR"

# Clean up
rm -rf "$WORK_DIR"
