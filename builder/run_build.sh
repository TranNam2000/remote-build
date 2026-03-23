#!/bin/bash
# run_build.sh — Runs inside Docker container for Android builds
set -e
[ "$LOG_VERBOSE" = "1" ] && set -x

source /common.sh

cd /app/source_code

LANE="${LANE:-release}"

optimize_gradle
flutter_prepare
setup_fastfile "android"
run_fastlane "android" "$LANE"
collect_android_artifact "/output"
