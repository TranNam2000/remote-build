#!/bin/bash
set -e

REPO_URL=$1
BRANCH=$2
BUILD_ID=${3:-"android_$(date +%s)"}
LANE=$4
WORK_DIR="/tmp/flutter_build_$BUILD_ID"
BUILDER_DIR="$PWD"
OUTPUT_DIR="${BUILDER_DIR}/completed_builds/$BUILD_ID"

echo "Starting Docker-based Android Build..."
mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

echo "Cloning repository on host..."
cd "$WORK_DIR"
if [ -n "$BRANCH" ]; then
    echo "Cloning branch: $BRANCH"
    git clone --branch "$BRANCH" "$REPO_URL" source_code
else
    git clone "$REPO_URL" source_code
fi

cd "$BUILDER_DIR"

# Ensure the docker image is built (you might want to run this fully outside the first time)
if [[ "$(docker images -q flutter-android-builder 2> /dev/null)" == "" ]]; then
    echo "Building Docker image flutter-android-builder..."
    docker build -t flutter-android-builder -f Dockerfile.android .
fi

echo "Running Docker container..."
docker run --rm \
    -v "$WORK_DIR/source_code:/app/source_code" \
    -v "$OUTPUT_DIR:/output" \
    -e LANE="$LANE" \
    flutter-android-builder

echo "Check output directory: $OUTPUT_DIR"

# Clean up
rm -rf "$WORK_DIR"
