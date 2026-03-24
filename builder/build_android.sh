#!/bin/bash
set -e

REPO_URL=$1
BRANCH=$2
BUILD_ID=${3:-"android_$(date +%s)"}
LANE=${4:-release}
BUILDER_DIR="$PWD"
WORK_DIR="/tmp/flutter_build_$BUILD_ID"
OUTPUT_DIR="${BUILDER_DIR}/completed_builds/$BUILD_ID"

source "$(dirname "$0")/common.sh"

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
optimize_gradle
flutter_prepare        # auto-skips if native
setup_fastfile "android"
run_fastlane "android" "$LANE"
collect_android_artifact "$OUTPUT_DIR"

cleanup_temp "$WORK_DIR"
