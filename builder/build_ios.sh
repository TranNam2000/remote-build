#!/bin/bash
set -e

REPO_URL=$1
BRANCH=$2
BUILD_ID=${3:-"ios_$(date +%s)"}
LANE=${4:-${FASTLANE_LANE:-"beta"}}
WORK_DIR_BASE="${WORK_DIR_BASE:-${TMPDIR:-/tmp}}"
WORK_DIR="${WORK_DIR_BASE%/}/flutter_build_$BUILD_ID"
OUTPUT_DIR="${PWD}/completed_builds/$BUILD_ID"

source "$(dirname "$0")/common.sh"

echo "Starting iOS Build..."
echo "Build ID: $BUILD_ID"

mkdir -p "$OUTPUT_DIR"

# Clone first to detect project type
clone_repo "$REPO_URL" "$BRANCH" "$WORK_DIR"
detect_project_type
load_env

# Setup prerequisites based on detected type
if [ "$PROJECT_TYPE" = "flutter" ]; then
    echo "📋 Flutter iOS project"
    setup_macos_prerequisites "ios"
    flutter_prepare
elif [ "$PROJECT_TYPE" = "native_ios" ]; then
    echo "📋 Native iOS project (Swift/Obj-C)"
    setup_macos_prerequisites "ios"
    # No flutter_prepare needed
else
    echo "📋 Project type: $PROJECT_TYPE — building as iOS"
    setup_macos_prerequisites "ios"
fi

# --- iOS-specific: detect bundle id ---
APP_IDENTIFIER=$(grep -m 1 "PRODUCT_BUNDLE_IDENTIFIER" ios/Runner.xcodeproj/project.pbxproj 2>/dev/null \
    | sed -E 's/.*= (.*);/\1/' | tr -d '"')
[ -n "$APP_IDENTIFIER" ] && export APP_IDENTIFIER && echo "Detected bundle id: $APP_IDENTIFIER"

# --- iOS-specific: App Store Connect API key ---
if [ -z "$ASC_KEY_PATH" ]; then
    ASC_KEY_PATH=$(find "$HOME" "$(dirname "$0")/.." -maxdepth 4 -type f -name "AuthKey_*.p8" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -n 1)
fi
if [ -n "$ASC_KEY_PATH" ] && [ -z "$ASC_KEY_ID" ]; then
    ASC_KEY_ID=$(basename "$ASC_KEY_PATH" | sed -E 's/^AuthKey_([A-Z0-9]+)\.p8$/\1/')
fi
if [ -z "$ASC_KEY_PATH" ] || [ -z "$ASC_ISSUER_ID" ] || [ -z "$ASC_KEY_ID" ]; then
    echo "Warning: Missing App Store Connect API key. TestFlight upload will be skipped."
    export SKIP_TESTFLIGHT=1
else
    export ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID
fi

# --- iOS-specific: DerivedData & cache ---
if [ "$CACHE_DERIVED_DATA" = "1" ]; then
    export DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${WORK_DIR_BASE%/}/DerivedData}"
    export FASTLANE_DERIVED_DATA_PATH="$DERIVED_DATA_PATH"
fi
echo "Cleaning old DerivedData..."
rm -rf "$HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null || true
if [ -n "$DERIVED_DATA_PATH" ]; then
    rm -rf "$DERIVED_DATA_PATH" 2>/dev/null || true
    mkdir -p "$DERIVED_DATA_PATH"
fi
export ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_DIR/source_code/build/ios/Runner.xcarchive}"

if [ "$CACHE_PODS" = "1" ]; then
    export COCOAPODS_CACHE_PATH="${COCOAPODS_CACHE_PATH:-$HOME/.cocoapods-cache}"
fi

# --- CocoaPods ---
cd ios
set +e
if command -v pod >/dev/null 2>&1; then
    export COCOAPODS_DISABLE_STATS=1
    if [ "$FORCE_POD_REPO_UPDATE" = "1" ]; then
        pod repo update --silent
    elif [ ! -d "$HOME/.cocoapods/repos" ] || [ -z "$(ls -A "$HOME/.cocoapods/repos" 2>/dev/null)" ]; then
        pod repo update --silent
    fi

    POD_CMD="pod"
    [ -f "Gemfile" ] && command -v bundle >/dev/null 2>&1 && POD_CMD="bundle exec pod"

    if ! $POD_CMD install; then
        if ! $POD_CMD install --repo-update; then
            $POD_CMD update PurchasesHybridCommon PurchasesHybridCommonUI || true
            if ! $POD_CMD install --repo-update; then
                rm -f Podfile.lock
                $POD_CMD install --repo-update
            fi
        fi
    fi
fi
set -e
cd ..

# --- Fastlane build ---
setup_fastfile "ios"
set +e
run_fastlane "ios" "$LANE"
FASTLANE_EXIT=$?
set -e

# --- Collect artifact ---
collect_ios_artifact "$OUTPUT_DIR"
echo "Saved output to: $OUTPUT_DIR"
cleanup_temp "$WORK_DIR"

