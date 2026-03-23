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

if [[ "$(uname)" == "Darwin" ]]; then
    echo "==> Building natively on macOS..."

    setup_macos_prerequisites "android"
    clone_repo "$REPO_URL" "$BRANCH" "$WORK_DIR"
    load_env
    optimize_gradle
    flutter_prepare
    setup_fastfile "android"
    run_fastlane "android" "$LANE"
    collect_android_artifact "$OUTPUT_DIR"

else
    echo "==> Building via Docker (Linux)..."

    clone_repo "$REPO_URL" "$BRANCH" "$WORK_DIR"
    cd "$BUILDER_DIR"

    if [[ "$(docker images -q flutter-android-builder 2>/dev/null)" == "" ]]; then
        echo "==> STEP: Docker build image"
        docker build --platform linux/arm64 -t flutter-android-builder -f Dockerfile.android .
    fi

    echo "==> STEP: Docker run build"
    docker run --platform linux/arm64 --rm \
        -v "$WORK_DIR/source_code:/app/source_code" \
        -v "$OUTPUT_DIR:/output" \
        -e LANE="$LANE" \
        -e LOG_VERBOSE=1 \
        flutter-android-builder &

    DOCKER_PID=$!
    while kill -0 "$DOCKER_PID" 2>/dev/null; do
        echo "Docker build still running..."
        sleep 30
    done

    wait "$DOCKER_PID"
    DOCKER_RC=$?
    [ "$DOCKER_RC" -ne 0 ] && exit "$DOCKER_RC"
fi

cleanup_temp "$WORK_DIR"
