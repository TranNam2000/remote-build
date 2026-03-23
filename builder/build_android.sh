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

setup_macos_prerequisites "android"
clone_repo "$REPO_URL" "$BRANCH" "$WORK_DIR"
detect_project_type
load_env
optimize_gradle
flutter_prepare        # auto-skips if native
setup_fastfile "android"
run_fastlane "android" "$LANE"
collect_android_artifact "$OUTPUT_DIR"

cleanup_temp "$WORK_DIR"
