#!/bin/bash
# builder/common.sh - Shared functions for Flutter Remote Builder

# Fix locale for CocoaPods, Fastlane, Ruby
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# --- Refresh PATH (pick up tools installed after server started) ---
refresh_path() {
    # Homebrew
    [ -d "/opt/homebrew/bin" ] && export PATH="/opt/homebrew/bin:$PATH"
    [ -d "/usr/local/bin" ] && export PATH="/usr/local/bin:$PATH"
    # Flutter
    [ -d "$HOME/flutter/bin" ] && export PATH="$HOME/flutter/bin:$PATH"
    [ -d "$HOME/fvm/default/bin" ] && export PATH="$HOME/fvm/default/bin:$PATH"
    [ -d "$HOME/.pub-cache/bin" ] && export PATH="$HOME/.pub-cache/bin:$PATH"
    # Ruby gems
    [ -d "$HOME/.gem/ruby/*/bin" ] && export PATH="$(echo $HOME/.gem/ruby/*/bin | tr ' ' ':'):$PATH"
    # Android SDK
    [ -d "$HOME/Library/Android/sdk" ] && export ANDROID_HOME="$HOME/Library/Android/sdk"
    [ -n "$ANDROID_HOME" ] && export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
}
refresh_path

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
        # Accept licenses only if not yet accepted
        if [ ! -f "$ANDROID_HOME/licenses/android-sdk-license" ]; then
            if command -v sdkmanager >/dev/null 2>&1; then
                echo "📦 Accepting SDK licenses..."
                yes | sdkmanager --licenses >/dev/null 2>&1 || true
            fi
        else
            echo "✅ SDK licenses already accepted"
        fi
        # Install platform-tools only if missing
        if [ ! -f "$ANDROID_HOME/platform-tools/adb" ]; then
            if command -v sdkmanager >/dev/null 2>&1; then
                echo "📦 Installing platform-tools..."
                sdkmanager "platform-tools" 2>/dev/null || true
            fi
        else
            echo "✅ platform-tools already installed"
        fi
        # Auto-install build-tools if no aapt2 found
        if [ -z "$(find "$ANDROID_HOME/build-tools" -name "aapt2" 2>/dev/null)" ]; then
            if command -v sdkmanager >/dev/null 2>&1; then
                echo "📦 Installing build-tools..."
                sdkmanager "build-tools;36.0.0" 2>/dev/null || true
            fi
        else
            echo "✅ build-tools already installed"
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

# --- GitHub API download helper ---
# Usage: download_github_zip <owner/repo> <ref> <token> <dest_parent_dir> <folder_name>
download_github_zip() {
    local repo_full="$1" ref="$2" token="$3" dest_dir="$4" folder_name="$5"
    local headers=(-H "User-Agent: Flutter-Remote-Builder")
    [ -n "$token" ] && headers+=(-H "Authorization: token $token")
    local zip_path="$dest_dir/_dl_${folder_name}.zip"
    local extract_path="$dest_dir/_ex_${folder_name}"
    echo "[INFO] Downloading $repo_full @ $ref ..."
    curl -fsSL "${headers[@]}" \
        "https://api.github.com/repos/$repo_full/zipball/$ref" \
        -o "$zip_path"
    mkdir -p "$extract_path"
    unzip -q "$zip_path" -d "$extract_path"
    rm -f "$zip_path"
    local extracted
    extracted=$(find "$extract_path" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -z "$extracted" ] && echo "[ERROR] Extracted folder not found for $repo_full" && return 1
    local dest="$dest_dir/$folder_name"
    rm -rf "$dest"
    mv "$extracted" "$dest"
    rm -rf "$extract_path"
}

# --- Git clone (via GitHub API) ---
# After calling this, PWD = $work_dir/source_code
clone_repo() {
    local repo_url="$1" branch="$2" work_dir="$3"
    echo "==> STEP: Git clone"
    mkdir -p "$work_dir"
    cd "$work_dir"
    rm -rf source_code 2>/dev/null || true

    # Extract token embedded in URL (https://oauth2:TOKEN@github.com/...)
    local token=""
    local clean_url="$repo_url"
    if [[ "$repo_url" =~ https://[^:]+:([^@]+)@ ]]; then
        token="${BASH_REMATCH[1]}"
        clean_url=$(echo "$repo_url" | sed 's|https://[^@]*@|https://|')
    fi

    # Parse owner/repo
    local repo_full
    repo_full=$(echo "$clean_url" | grep -oP 'github\.com[:/]\K[\w.\-]+/[\w.\-]+?(?=\.git|$)')
    [ -z "$repo_full" ] && echo "[ERROR] Cannot parse GitHub repo from: $clean_url" && exit 1

    local ref="${branch:-HEAD}"
    echo "Repository: $repo_full @ $ref"
    download_github_zip "$repo_full" "$ref" "$token" "$work_dir" "source_code"
    cd source_code

    # Handle submodules via API
    if [ -f ".gitmodules" ]; then
        echo "[INFO] Submodules detected, downloading via API..."
        local api_headers=(-H "User-Agent: Flutter-Remote-Builder")
        [ -n "$token" ] && api_headers+=(-H "Authorization: token $token")

        # Fetch pinned commit SHAs from GitHub tree API
        declare -A pinned_shas=()
        local tree_json
        tree_json=$(curl -fsSL "${api_headers[@]}" \
            "https://api.github.com/repos/$repo_full/git/trees/$ref?recursive=1" 2>/dev/null || true)
        while IFS= read -r item_path && IFS= read -r item_sha; do
            pinned_shas["$item_path"]="$item_sha"
        done < <(echo "$tree_json" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for t in data.get('tree',[]):
    if t.get('type')=='commit':
        print(t['path']); print(t['sha'])
" 2>/dev/null || true)

        # Parse .gitmodules by block
        local sm_path="" sm_url=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[submodule ]]; then
                sm_path=""; sm_url=""
            elif [[ "$line" =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.+) ]]; then
                sm_path="${BASH_REMATCH[1]// /}"
            elif [[ "$line" =~ ^[[:space:]]*url[[:space:]]*=[[:space:]]*(.+) ]]; then
                sm_url="${BASH_REMATCH[1]// /}"
                sm_url=$(echo "$sm_url" | sed 's|git@github\.com:|https://github.com/|')
                local sm_repo
                sm_repo=$(echo "$sm_url" | grep -oP 'github\.com[:/]\K[\w.\-]+/[\w.\-]+?(?=\.git|$)')
                if [ -n "$sm_repo" ] && [ -n "$sm_path" ]; then
                    local sm_ref="${pinned_shas[$sm_path]:-HEAD}"
                    echo "[INFO] Submodule: $sm_path @ $sm_ref"
                    local sm_parent; sm_parent=$(dirname "$sm_path")
                    local sm_name;   sm_name=$(basename "$sm_path")
                    mkdir -p "$sm_parent"
                    download_github_zip "$sm_repo" "$sm_ref" "$token" "$sm_parent" "$sm_name"
                    echo "[OK] Submodule: $sm_path"
                fi
            fi
        done < .gitmodules
        echo "[OK] All submodules downloaded"
    fi

    # Fix executable permissions
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

    echo "📦 Checking required SDK components from project..."

    # Only scan the main app's build.gradle — plugins/dependencies don't need separate platforms
    local gradle_files=""
    for gf in app/build.gradle app/build.gradle.kts android/app/build.gradle android/app/build.gradle.kts; do
        [ -f "$gf" ] && gradle_files="$gradle_files $gf"
    done
    [ -z "$gradle_files" ] && return 0

    local sdk_versions
    sdk_versions=$(echo "$gradle_files" \
        | xargs grep -hE 'compileSdk|compileSdkVersion' 2>/dev/null \
        | grep -oE '[0-9]+' | sort -un)

    local bt_versions
    bt_versions=$(echo "$gradle_files" \
        | xargs grep -hE 'buildToolsVersion' 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -un)

    # Check what's missing
    local need_install=0

    for ver in $sdk_versions; do
        [ "$ver" -lt 21 ] 2>/dev/null && continue
        if [ ! -d "$ANDROID_HOME/platforms/android-$ver" ]; then
            need_install=1
            break
        fi
    done

    if [ "$need_install" = "0" ]; then
        for btv in $bt_versions; do
            if [ ! -d "$ANDROID_HOME/build-tools/$btv" ]; then
                need_install=1
                break
            fi
        done
    fi

    # Also check fallback: no build-tools at all
    local need_fallback_bt=0
    if [ -z "$bt_versions" ] && [ -z "$(ls -A "$ANDROID_HOME/build-tools" 2>/dev/null)" ]; then
        need_fallback_bt=1
        need_install=1
    fi

    # Nothing to install
    if [ "$need_install" = "0" ]; then
        echo "✅ All required SDK components already installed"
        return 0
    fi

    # Accept licenses only when needed
    if [ ! -f "$ANDROID_HOME/licenses/android-sdk-license" ]; then
        echo "📦 Accepting SDK licenses..."
        yes | sdkmanager --licenses >/dev/null 2>&1 || true
    fi

    # Install missing platforms
    for ver in $sdk_versions; do
        [ "$ver" -lt 21 ] 2>/dev/null && continue
        if [ ! -d "$ANDROID_HOME/platforms/android-$ver" ]; then
            echo "📦 Installing platforms;android-$ver..."
            yes | sdkmanager "platforms;android-$ver" 2>/dev/null || true
        else
            echo "✅ platforms;android-$ver already installed"
        fi
    done

    # Install missing build-tools
    for btv in $bt_versions; do
        if [ ! -d "$ANDROID_HOME/build-tools/$btv" ]; then
            echo "📦 Installing build-tools;$btv..."
            yes | sdkmanager "build-tools;$btv" 2>/dev/null || true
        else
            echo "✅ build-tools;$btv already installed"
        fi
    done

    # Fallback: no build-tools specified and none installed
    if [ "$need_fallback_bt" = "1" ]; then
        local fallback_ver
        fallback_ver=$(echo "$sdk_versions" | tail -n 1)
        if [ -n "$fallback_ver" ]; then
            echo "📦 No build-tools specified, installing build-tools;${fallback_ver}.0.0..."
            yes | sdkmanager "build-tools;${fallback_ver}.0.0" 2>/dev/null || true
        fi
    fi
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
    # Remove existing Gradle tuning keys from ALL properties files so our values take effect
    for pf in gradle.properties android/gradle.properties; do
        if [ -f "$pf" ]; then
            sed -i '/^org\.gradle\.jvmargs=/d;/^org\.gradle\.daemon=/d;/^org\.gradle\.parallel=/d;/^org\.gradle\.caching=/d;/^org\.gradle\.workers\.max=/d' "$pf"
        fi
    done
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
        if ! grep -q '^android\.aapt2FromMavenOverride=' "$props" 2>/dev/null; then
            echo "android.aapt2FromMavenOverride=$aapt2_path" >> "$props"
        fi
    else
        echo "⚠️  No aapt2 found. Build may fail."
    fi

    # --- JVM / Gradle performance tuning ---
    echo "Killing stale Gradle daemons..."
    pkill -f 'GradleDaemon' 2>/dev/null || true
    sleep 2

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
    local total_mb
    total_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1048576}' || echo 8192)
    local avail_mb
    avail_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $7}' || vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); print int($3*4096/1048576)}' || echo 4096)
    # Reserve 2GB for OS + Flutter/Dart, use the rest for Gradle heap
    local reserve_mb=2048
    local heap_mb=$(( avail_mb - reserve_mb ))
    # Cap: max 60% of total RAM or 8192MB (whichever is smaller)
    local heap_cap=$(( total_mb * 60 / 100 ))
    [ "$heap_cap" -gt 8192 ] && heap_cap=8192
    [ "$heap_mb" -lt 1024 ] && heap_mb=1024
    [ "$heap_mb" -gt "$heap_cap" ] && heap_mb=$heap_cap
    local workers_max=2
    echo "✅ Detected: ${cpu_cores} cores, ${total_mb}MB total, ${avail_mb}MB free -> heap=${heap_mb}m, workers=${workers_max}"

    grep -q '^android\.useAndroidX=' "$props" 2>/dev/null || echo "android.useAndroidX=true" >> "$props"
    grep -q '^android\.nonTransitiveRClass=' "$props" 2>/dev/null || echo "android.nonTransitiveRClass=true" >> "$props"
    echo "org.gradle.daemon=false" >> "$props"
    echo "org.gradle.jvmargs=-Xmx${heap_mb}m -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError" >> "$props"
    echo "org.gradle.parallel=true" >> "$props"
    echo "org.gradle.caching=false" >> "$props"
    echo "org.gradle.workers.max=$workers_max" >> "$props"
    echo "kotlin.compiler.execution.strategy=in-process" >> "$props"

    # --- Auto-inject ProGuard/R8 dontwarn rules ---
    for pg_file in proguard-rules.pro app/proguard-rules.pro android/app/proguard-rules.pro; do
        if [ -f "$pg_file" ]; then
            if ! grep -q "dontwarn com.bytedance.sdk.openadsdk" "$pg_file" 2>/dev/null; then
                echo "-dontwarn com.bytedance.sdk.openadsdk.**" >> "$pg_file"
                echo "-dontwarn com.facebook.infer.annotation.**" >> "$pg_file"
                echo "✅ Injected dontwarn rules into $pg_file"
            fi
        fi
    done
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
            # Native Android - use gradle directly with flavor from FLAVOR env
            local flavor_cap=""
            if [ -n "$FLAVOR" ]; then
                flavor_cap="$(echo "${FLAVOR:0:1}" | tr '[:lower:]' '[:upper:]')${FLAVOR:1}"
            fi
            cat > "${target_dir}/fastlane/Fastfile" <<NEOF
# Codex managed Fastfile - Native Android
default_platform(:android)

platform :android do
  desc "Build release APK (native Android)"
  lane :release do
    gradle(task: "assemble${flavor_cap}Release", flags: "--no-daemon", print_command: true)
  end

  desc "Build release AAB (native Android)"
  lane :bundle do
    gradle(task: "bundle${flavor_cap}Release", flags: "--no-daemon", print_command: true)
  end
end
NEOF
        elif [ "$platform" = "android" ]; then
            # Flutter Android with flavor from FLAVOR env
            local flavor_flag=""
            [ -n "$FLAVOR" ] && flavor_flag=" --flavor $FLAVOR"
            cat > "${platform}/fastlane/Fastfile" <<EOF
# Codex managed Fastfile — Flutter Android
default_platform(:android)

platform :android do
  desc "Build release APK"
  lane :release do
    sh("cd .. && flutter build apk --release${flavor_flag}")
  end

  desc "Build AAB"
  lane :bundle do
    sh("cd .. && flutter build appbundle --release${flavor_flag}")
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
