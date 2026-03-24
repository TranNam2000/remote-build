#!/bin/bash
# builder/common.sh — Shared functions for Flutter Remote Builder

# Fix locale for CocoaPods, Fastlane, Ruby
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# --- Auto-install prerequisites on macOS ---
# Usage: setup_macos_prerequisites "android" | "ios"
setup_macos_prerequisites() {
    local platform="${1:-android}"
    echo "==> STEP: Setup prerequisites"

    # Homebrew
    if ! command -v brew >/dev/null 2>&1; then
        echo "📦 Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" || eval "$(/usr/local/bin/brew shellenv 2>/dev/null)" || true
    echo "✅ Homebrew"

    # Java 17 (Android/Gradle)
    if [ "$platform" = "android" ]; then
        if ! command -v java >/dev/null 2>&1; then
            echo "📦 Installing OpenJDK 17..."
            brew install openjdk@17
            sudo ln -sfn "$(brew --prefix openjdk@17)/libexec/openjdk.jdk" \
                /Library/Java/JavaVirtualMachines/openjdk-17.jdk 2>/dev/null || true
        fi
        if [ -z "$JAVA_HOME" ]; then
            local java_prefix
            java_prefix="$(brew --prefix openjdk@17 2>/dev/null)"
            if [ -d "$java_prefix/libexec/openjdk.jdk/Contents/Home" ]; then
                export JAVA_HOME="$java_prefix/libexec/openjdk.jdk/Contents/Home"
                export PATH="$JAVA_HOME/bin:$PATH"
            fi
        fi
        echo "✅ Java: $(java -version 2>&1 | head -n 1)"
    fi

    # Ruby / gem
    if ! command -v gem >/dev/null 2>&1; then
        echo "📦 Installing Ruby..."
        brew install ruby
    fi
    # Prefer Homebrew Ruby over RVM/system Ruby to avoid gem conflicts
    local brew_ruby_bin
    brew_ruby_bin="$(brew --prefix ruby 2>/dev/null)/bin"
    [ -d "$brew_ruby_bin" ] && export PATH="$brew_ruby_bin:$PATH"
    local gem_bin
    gem_bin="$(gem environment gemdir 2>/dev/null)/bin"
    [ -d "$gem_bin" ] && export PATH="$gem_bin:$PATH"
    echo "✅ Ruby: $(ruby --version 2>/dev/null)"

    # Flutter (only if project uses Flutter)
    if [ "$PROJECT_TYPE" = "flutter" ]; then
        if ! command -v flutter >/dev/null 2>&1; then
            echo "📦 Installing Flutter..."
            brew install --cask flutter
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" || eval "$(/usr/local/bin/brew shellenv 2>/dev/null)" || true
        fi
        echo "✅ Flutter: $(flutter --version 2>/dev/null | head -n 1)"
    else
        echo "⊘ Skipping Flutter (native project)"
    fi

    # Fastlane — verify it actually runs (not just a broken RVM shim)
    if ! fastlane --version >/dev/null 2>&1; then
        echo "📦 Installing Fastlane..."
        gem install fastlane --no-document
    fi
    echo "✅ Fastlane: $(fastlane --version 2>/dev/null | tail -n 1)"

    # Android SDK
    if [ "$platform" = "android" ]; then
        if [ -z "$ANDROID_HOME" ] || [ ! -d "$ANDROID_HOME" ]; then
            if [ -d "$HOME/Library/Android/sdk" ]; then
                export ANDROID_HOME="$HOME/Library/Android/sdk"
            else
                echo "📦 Installing Android SDK..."
                brew install --cask android-commandlinetools
                export ANDROID_HOME="$HOME/Library/Android/sdk"
                mkdir -p "$ANDROID_HOME"
            fi
        fi
        export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"
        if command -v sdkmanager >/dev/null 2>&1; then
            echo "📦 Checking Android SDK components..."
            yes | sdkmanager --licenses >/dev/null 2>&1 || true
            sdkmanager "platform-tools" 2>/dev/null || true
            # Auto-install build-tools if no aapt2 found
            if [ -z "$(find "$ANDROID_HOME/build-tools" -name "aapt2" 2>/dev/null)" ]; then
                sdkmanager "build-tools;36.0.0" 2>/dev/null || true
            fi
        fi
        echo "✅ Android SDK: $ANDROID_HOME"
    fi

    # iOS: Xcode & CocoaPods
    if [ "$platform" = "ios" ]; then
        if ! command -v xcodebuild >/dev/null 2>&1; then
            echo "⚠️  Xcode not found. Please install from App Store or run: xcode-select --install"
        else
            echo "✅ Xcode: $(xcodebuild -version 2>/dev/null | head -n 1)"
        fi
        if ! command -v pod >/dev/null 2>&1; then
            echo "📦 Installing CocoaPods..."
            gem install cocoapods --no-document
        fi
        echo "✅ CocoaPods"
    fi
}

# --- Git clone ---
# After calling this, PWD = $work_dir/source_code
clone_repo() {
    local repo_url="$1" branch="$2" work_dir="$3"
    echo "==> STEP: Git clone"
    mkdir -p "$work_dir"
    cd "$work_dir"
    if [ -n "$branch" ]; then
        echo "Cloning branch: $branch"
        git clone --branch "$branch" "$repo_url" source_code
    else
        git clone "$repo_url" source_code
    fi
    cd source_code
    # Fix executable permissions (gradlew, etc.)
    chmod +x gradlew 2>/dev/null || true
    chmod +x android/gradlew 2>/dev/null || true
}

# --- Load .env ---
load_env() {
    if [ -f ".env" ]; then
        echo "Loading .env from repository..."
        set -a; . ./.env; set +a
    fi
}

# --- Detect project type ---
# Sets global: PROJECT_TYPE ("flutter" | "native_android" | "native_ios")
detect_project_type() {
    if [ -f "pubspec.yaml" ]; then
        PROJECT_TYPE="flutter"
    elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "app/build.gradle" ] || [ -f "app/build.gradle.kts" ]; then
        PROJECT_TYPE="native_android"
    elif [ -f "*.xcodeproj" ] || [ -d "*.xcworkspace" ] || ls *.xcodeproj >/dev/null 2>&1; then
        PROJECT_TYPE="native_ios"
    else
        PROJECT_TYPE="flutter"  # default
    fi
    echo "📋 Detected project type: $PROJECT_TYPE"
}

# --- Flutter pub get + code generation ---
flutter_prepare() {
    if [ "$PROJECT_TYPE" != "flutter" ]; then
        echo "==> SKIP: flutter_prepare (not a Flutter project)"
        return 0
    fi

    echo "==> STEP: flutter pub get"
    flutter pub get

    if grep -q "build_runner" pubspec.yaml 2>/dev/null; then
        echo "==> STEP: build_runner"
        flutter pub run build_runner build --delete-conflicting-outputs
    fi

    if [ -f "scripts/generate.dart" ]; then
        echo "==> STEP: scripts/generate.dart"
        dart run scripts/generate.dart
    fi
}

# --- Auto-install required Android SDK from project ---
install_required_sdk() {
    if ! command -v sdkmanager >/dev/null 2>&1 || [ -z "$ANDROID_HOME" ]; then
        return 0
    fi

    echo "📦 Checking required SDK platforms..."

    # Only scan compileSdk — that's what actually needs to be installed
    local sdk_versions
    sdk_versions=$(find . -name "build.gradle" -o -name "build.gradle.kts" 2>/dev/null \
        | xargs grep -hE 'compileSdk|compileSdkVersion' 2>/dev/null \
        | grep -oE '[0-9]+' | sort -un)

    for ver in $sdk_versions; do
        [ "$ver" -lt 21 ] 2>/dev/null && continue
        if [ ! -d "$ANDROID_HOME/platforms/android-$ver" ]; then
            echo "📦 Installing platforms;android-$ver (required by project)..."
            yes | sdkmanager "platforms;android-$ver" 2>/dev/null || true
        else
            echo "✅ platforms;android-$ver already installed"
        fi
    done
}


# --- Optimize gradle.properties (Android / Apple Silicon) ---
optimize_gradle() {
    echo "Optimizing gradle.properties..."
    local props
    if [ "$PROJECT_TYPE" = "native_android" ]; then
        props="gradle.properties"
    else
        props="android/gradle.properties"
        mkdir -p android
    fi
    [ -f "$props" ] && echo "" >> "$props"

    # Find the latest aapt2 binary from installed build-tools
    local aapt2_path=""
    if [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME/build-tools" ]; then
        aapt2_path=$(find "$ANDROID_HOME/build-tools" -name "aapt2" -type f 2>/dev/null | sort -V | tail -n 1)
    fi
    # If no aapt2 found, install latest build-tools via sdkmanager
    if [ -z "$aapt2_path" ] && command -v sdkmanager >/dev/null 2>&1; then
        echo "📦 No aapt2 found. Installing latest build-tools..."
        local latest_bt
        latest_bt=$(sdkmanager --list 2>/dev/null | grep "build-tools;" | tail -n 1 | awk '{print $1}')
        if [ -n "$latest_bt" ]; then
            yes | sdkmanager "$latest_bt" >/dev/null 2>&1 || true
            aapt2_path=$(find "$ANDROID_HOME/build-tools" -name "aapt2" -type f 2>/dev/null | sort -V | tail -n 1)
        fi
    fi
    if [ -n "$aapt2_path" ]; then
        echo "Using aapt2: $aapt2_path"
        echo "android.aapt2FromMavenOverride=$aapt2_path" >> "$props"
    else
        echo "⚠️  No aapt2 found. Build may fail."
    fi


    echo "org.gradle.daemon=true" >> "$props"
    echo "org.gradle.parallel=false" >> "$props"
    echo "org.gradle.caching=false" >> "$props"
    echo "org.gradle.workers.max=2" >> "$props"
    echo "android.enableR8.fullMode=false" >> "$props"
}

# --- Setup Fastfile for platform ---
# Sets global: FASTFILE_PATH
setup_fastfile() {
    local platform="$1" # "android" or "ios"
    FASTFILE_PATH=""
    local managed=0

    # For native Android, Fastfile lives at root level (fastlane/Fastfile)
    # For Flutter, it lives at android/fastlane/Fastfile or ios/fastlane/Fastfile
    local search_dir="$platform"
    [ "$PROJECT_TYPE" = "native_android" ] && search_dir="."

    if [ -f "${search_dir}/fastlane/Fastfile" ]; then
        FASTFILE_PATH="${search_dir}/fastlane/Fastfile"
    elif [ -f "${search_dir}/Fastfile" ]; then
        FASTFILE_PATH="${search_dir}/Fastfile"
    fi

    [ -n "$FASTFILE_PATH" ] && grep -q "Codex managed Fastfile" "$FASTFILE_PATH" && managed=1

    if [ -z "$FASTFILE_PATH" ] || [ "$managed" = "1" ]; then
        local target_dir="$platform"
        [ "$PROJECT_TYPE" = "native_android" ] && target_dir="."
        echo "Generating default Fastlane config for ${platform} (${PROJECT_TYPE})..."
        mkdir -p "${target_dir}/fastlane"

        if [ "$platform" = "android" ] && [ "$PROJECT_TYPE" = "native_android" ]; then
            # Native Android — use gradle directly
            cat > "${target_dir}/fastlane/Fastfile" <<'NEOF'
# Codex managed Fastfile — Native Android
default_platform(:android)

platform :android do
  desc "Build release APK (native Android)"
  lane :release do
    gradle(
      task: "assembleRelease"
    )
  end

  desc "Build release AAB (native Android)"
  lane :bundle do
    gradle(
      task: "bundleRelease"
    )
  end
end
NEOF
        elif [ "$platform" = "android" ]; then
            # Flutter Android
            cat > "${platform}/fastlane/Fastfile" <<'EOF'
# Codex managed Fastfile — Flutter Android
default_platform(:android)

platform :android do
  desc "Build release APK"
  lane :release do
    sh("cd .. && flutter build apk --release")
  end

  desc "Build release AAB"
  lane :bundle do
    sh("cd .. && flutter build appbundle --release")
  end
end
EOF
        else
            cat > "${platform}/fastlane/Fastfile" <<'EOF'
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
        fi
        FASTFILE_PATH="${target_dir}/fastlane/Fastfile"
    fi
}

# --- Run Fastlane ---
run_fastlane() {
    local platform="$1" lane="$2"
    echo "==> STEP: Fastlane"
    echo "🚀 Running Fastlane lane: $lane for $platform ($PROJECT_TYPE)..."

    # For native Android, fastlane is at root; for Flutter, inside platform dir
    local run_dir="$platform"
    [ "$PROJECT_TYPE" = "native_android" ] && run_dir="."

    cd "$run_dir"
    local fastfile_flag=""
    [ "$FASTFILE_PATH" = "${run_dir}/Fastfile" ] && fastfile_flag="--fastfile Fastfile"

    if [ -f "Gemfile" ] && command -v bundle >/dev/null 2>&1; then
        bundle install
        bundle exec fastlane $fastfile_flag "$lane"
    else
        fastlane $fastfile_flag "$lane"
    fi
    [ "$run_dir" != "." ] && cd ..
}

# --- Collect Android artifact ---
collect_android_artifact() {
    local output_dir="$1"
    echo "==> STEP: Collect artifact"
    local artifact=""
    if [ "$PROJECT_TYPE" = "native_android" ]; then
        # Native Android: APK in app/build/outputs/
        artifact=$(find . -path "*/build/outputs/*" \( -name "*.apk" -o -name "*.aab" \) ! -name "*debug*" 2>/dev/null | head -n 1)
    else
        # Flutter: APK in build/app/outputs/
        artifact=$(find build/app/outputs -name "*.apk" -o -name "*.aab" 2>/dev/null | head -n 1)
    fi
    if [ -n "$artifact" ]; then
        local filename
        filename=$(basename "$artifact")
        cp "$artifact" "$output_dir/$filename"
        echo "Saved to $output_dir/$filename"
    else
        echo "Error: No build artifact found!"
        exit 1
    fi
}

# --- Collect iOS artifact ---
collect_ios_artifact() {
    local output_dir="$1"
    echo "==> STEP: Collect artifact"
    local ipa_path xcarchive_path
    ipa_path=$(find . -type f -name "*.ipa" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1)
    xcarchive_path=$(find . -type d -name "*.xcarchive" -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -n 1)
    [ -n "$ARCHIVE_PATH" ] && [ -d "$ARCHIVE_PATH" ] && xcarchive_path="$ARCHIVE_PATH"

    if [ -n "$ipa_path" ] && [ -f "$ipa_path" ]; then
        cp "$ipa_path" "$output_dir/Runner.ipa"
        echo "Saved to: $output_dir/Runner.ipa"
    elif [ -n "$xcarchive_path" ] && [ -d "$xcarchive_path" ]; then
        (cd "$(dirname "$xcarchive_path")" && zip -r "$output_dir/Runner.xcarchive.zip" "$(basename "$xcarchive_path")")
        echo "Saved to: $output_dir/Runner.xcarchive.zip"
    else
        echo "Error: No .ipa or .xcarchive found!"
        exit 1
    fi
}

# --- Cleanup ---
cleanup_temp() {
    [ -n "$1" ] && [ -d "$1" ] && rm -rf "$1"
}

cleanup_old_builds() {
    local base_dir="$1" age_hours="${2:-1}"
    echo "Cleaning old temp build folders..."
    find "$base_dir" -maxdepth 1 -type d -name "flutter_build_*" \
        -mmin +$((age_hours * 60)) -print0 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true
}
