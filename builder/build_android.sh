#!/bin/bash
set -e

REPO_URL=$1
BRANCH=$2
BUILD_ID=${3:-"android_$(date +%s)"}
LANE=${4:-release}
FLAVOR=${5:-""}
BUILDER_DIR="$PWD"
WORK_DIR="/tmp/flutter_build_$BUILD_ID"
OUTPUT_DIR="${BUILDER_DIR}/completed_builds/$BUILD_ID"

source "$(dirname "$0")/common.sh"

cleanup_workdir() {
    cd "$BUILDER_DIR" || true
    cleanup_temp "$WORK_DIR"
    echo "[CLEANUP] Removed temp source folder: $WORK_DIR"
}
trap cleanup_workdir EXIT

echo "Starting Android Build..."
echo "Build ID: $BUILD_ID"
mkdir -p "$OUTPUT_DIR"

# Clone first to detect project type before setting up prerequisites
clone_repo "$REPO_URL" "$BRANCH" "$WORK_DIR"
detect_project_type

# Setup prerequisites based on detected project type
if [ "$PROJECT_TYPE" = "flutter" ]; then
    echo "📋 Detected Flutter project"
    setup_macos_prerequisites "flutter"
else
    echo "📋 Detected Native Android project"
    setup_macos_prerequisites "android"
fi
load_env
install_required_sdk
optimize_gradle
flutter_prepare        # auto-skips if native

export FLAVOR
echo "🎨 Flavor: ${FLAVOR:-"(none)"}"
setup_fastfile "android"

set +e
run_fastlane "android" "$LANE"
FASTLANE_EXIT=$?
set -e

# Fastlane may exit 1 due to locale warning even on success — check artifact instead
collect_android_artifact "$OUTPUT_DIR"

