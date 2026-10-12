#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ci-utils.sh
source "$SCRIPT_DIR/ci-utils.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_REVISION=""
OUTPUT_DIR=""
DERIVED_DATA=""
PACKAGE_CLONES=""
PACKAGE_LOCK=""
ARTIFACT_ID="enviouswispr-9.30.1-r1"

usage() {
    log_info "Usage: $0 [named parameters]"
    log_info "  -r, --source-revision <commit>  Exact clean checkout revision (required)"
    log_info "  -o, --output-dir <path>         Fresh absolute output directory (required)"
    log_info "  -d, --derived-data <path>       Fresh absolute DerivedData directory (required)"
    log_info "  -p, --package-clones <path>     Existing isolated package clones (required)"
    log_info "  -l, --package-lock <path>       Proven generated Xcode dependency lock (required)"
    log_info "  -i, --artifact-id <name>        Distinct fork identifier (default: $ARTIFACT_ID)"
    log_info "  -h, --help                      Show usage"
}

fail() { log_error "$*"; exit 1; }
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -h || "$1" == --help ]]; then usage; exit 0; fi
    [[ $# -ge 2 ]] || fail "Missing value for $1"
    case "$1" in
        -r|--source-revision) SOURCE_REVISION="$2" ;;
        -o|--output-dir) OUTPUT_DIR="$2" ;;
        -d|--derived-data) DERIVED_DATA="$2" ;;
        -p|--package-clones) PACKAGE_CLONES="$2" ;;
        -l|--package-lock) PACKAGE_LOCK="$2" ;;
        -i|--artifact-id) ARTIFACT_ID="$2" ;;
        *) fail "Unknown parameter: $1" ;;
    esac
    shift 2
done
[[ -n "$SOURCE_REVISION" && -n "$OUTPUT_DIR" && -n "$DERIVED_DATA" && -n "$PACKAGE_CLONES" && -n "$PACKAGE_LOCK" ]] || fail "All required parameters must be supplied"
[[ "$ARTIFACT_ID" =~ ^enviouswispr-[A-Za-z0-9._-]+$ ]] || fail "Artifact identifier must start with enviouswispr- and contain only safe filename characters"
[[ "${SDK_V10:-0}" == 0 ]] || fail "This profile requires the legacy V9 backend"
for path in "$OUTPUT_DIR" "$DERIVED_DATA" "$PACKAGE_CLONES" "$PACKAGE_LOCK"; do
    [[ "$path" == /* ]] || fail "Paths must be absolute: $path"
done
for path in "$OUTPUT_DIR" "$DERIVED_DATA"; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "Refusing existing output: $path"
done
canonical_path() { python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$1"; }
OUTPUT_DIR="$(canonical_path "$OUTPUT_DIR")"
DERIVED_DATA="$(canonical_path "$DERIVED_DATA")"
PACKAGE_CLONES="$(canonical_path "$PACKAGE_CLONES")"
PACKAGE_LOCK="$(canonical_path "$PACKAGE_LOCK")"
for path in "$OUTPUT_DIR" "$DERIVED_DATA"; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "Refusing existing output: $path"
    [[ "$path/" != "$REPO_ROOT/"* && "$REPO_ROOT/" != "$path/"* ]] || fail "Build outputs must be outside the source checkout"
    [[ "$path/" != "$PACKAGE_CLONES/"* && "$PACKAGE_CLONES/" != "$path/"* ]] || fail "Build outputs must not overlap package clones"
done
[[ "$OUTPUT_DIR/" != "$DERIVED_DATA/"* && "$DERIVED_DATA/" != "$OUTPUT_DIR/"* ]] || fail "Output and DerivedData must not overlap"
[[ -d "$PACKAGE_CLONES" && -f "$PACKAGE_LOCK" ]] || fail "Existing package clones and generated lock are required"
cd "$REPO_ROOT"
SOURCE_COMMIT="$(git rev-parse --verify --end-of-options "$SOURCE_REVISION^{commit}")"
[[ "$SOURCE_COMMIT" == "$(git rev-parse HEAD)" ]] || fail "Checkout HEAD does not match the explicit source revision"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail "Source checkout must be clean"
git merge-base --is-ancestor 4b67ceb57b0e452c473ca900f6a24f3c021f1e24 "$SOURCE_COMMIT" || fail "Reviewed receiver and caller fixes are absent"
LOCK_SHA="$(shasum -a 256 "$PACKAGE_LOCK" | awk '{print $1}')"
[[ "$LOCK_SHA" == f14bc3972aee38fdb27a9e86d37b31319b06a15bfb8eafe59241dcfa7815539b ]] || fail "Dependency lock differs from the qualified stock pin"
[[ "$(git -C "$PACKAGE_CLONES/checkouts/KSCrash" rev-parse HEAD)" == 18a633dec20c265f03386294f9d82d208bb13094 ]] || fail "KSCrash checkout revision differs from the lock"
[[ -z "$(git -C "$PACKAGE_CLONES/checkouts/KSCrash" status --porcelain --untracked-files=no)" ]] || fail "KSCrash checkout has tracked changes"
PROJECT_LOCK="$REPO_ROOT/Sentry.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
git check-ignore -q "$PROJECT_LOCK" || fail "Generated project lock must be ignored"
if [[ -e "$PROJECT_LOCK" ]]; then
    cmp -s "$PACKAGE_LOCK" "$PROJECT_LOCK" || fail "Existing project lock differs; refusing overwrite"
else
    mkdir -p "$(dirname "$PROJECT_LOCK")"
    cp "$PACKAGE_LOCK" "$PROJECT_LOCK"
fi
mkdir "$OUTPUT_DIR" "$DERIVED_DATA"
cp "$PACKAGE_LOCK" "$OUTPUT_DIR/Package.resolved"
git rev-parse HEAD 'HEAD^{tree}' > "$OUTPUT_DIR/source-revision.txt"
git diff --stat 4f135c52afeeb1d6937eb93824c7ec1cddcaa372 HEAD > "$OUTPUT_DIR/source-delta.txt"
xcodebuild -version > "$OUTPUT_DIR/toolchain.txt"
xcrun swift --version >> "$OUTPUT_DIR/toolchain.txt"
ARCHIVE="$OUTPUT_DIR/archive/Sentry/macosx.xcarchive"
BUILD_ARGS=(-project Sentry.xcodeproj/ -scheme Sentry -configuration Release -sdk macosx
    -destination generic/platform=macOS -derivedDataPath "$DERIVED_DATA"
    -clonedSourcePackagesDirPath "$PACKAGE_CLONES" -onlyUsePackageVersionsFromResolvedFile
    -disableAutomaticPackageResolution CODE_SIGNING_REQUIRED=NO SKIP_INSTALL=NO
    CODE_SIGN_IDENTITY= MACH_O_TYPE=staticlib ENABLE_CODE_COVERAGE=NO
    GCC_GENERATE_DEBUGGING_SYMBOLS=YES OTHER_LDFLAGS= DEBUG_INFORMATION_FORMAT=dwarf
    STRIP_INSTALLED_PRODUCT=NO)
python3 -c 'import json,sys; json.dump(sys.argv[1:],sys.stdout,indent=2)' xcodebuild archive "${BUILD_ARGS[@]}" -archivePath "$ARCHIVE" > "$OUTPUT_DIR/archive-argv.json"
xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings -json > "$OUTPUT_DIR/effective-settings.json" 2> "$OUTPUT_DIR/settings.log"
log_info "Building reviewed Sentry source $SOURCE_COMMIT"
xcodebuild archive "${BUILD_ARGS[@]}" -archivePath "$ARCHIVE" > "$OUTPUT_DIR/archive.log" 2>&1
plutil -replace MinimumOSVersion -string 100.0 "$ARCHIVE/Products/Library/Frameworks/Sentry.framework/Resources/Info.plist"
bash "$SCRIPT_DIR/assemble-xcframework.sh" --scheme Sentry --sdks macosx --archive-template "$OUTPUT_DIR/archive/Sentry/SDK_NAME.xcarchive" --output "$OUTPUT_DIR/Sentry.xcframework" > "$OUTPUT_DIR/assembly.log" 2>&1
FRAMEWORK="$OUTPUT_DIR/Sentry.xcframework/macos-arm64_arm64e_x86_64/Sentry.framework/Sentry"
xcrun lipo -archs "$FRAMEWORK" > "$OUTPUT_DIR/architectures.txt"
xcrun dwarfdump --debug-info "$FRAMEWORK" > "$OUTPUT_DIR/framework-dwarf.txt"
ZIP_PATH="$OUTPUT_DIR/Sentry-$ARTIFACT_ID.xcframework.zip"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_DIR/Sentry.xcframework" "$ZIP_PATH"
unzip -l "$ZIP_PATH" > "$OUTPUT_DIR/archive-entries.txt"
xcrun swift package compute-checksum "$ZIP_PATH" > "$OUTPUT_DIR/swiftpm-checksum.txt"
shasum -a 256 "$FRAMEWORK" "$ZIP_PATH" "$SCRIPT_DIR/build-enviouswispr-macos-artifact.sh" "$SCRIPT_DIR/assemble-xcframework.sh" "$SCRIPT_DIR/ci-utils.sh" "$REPO_ROOT/Sources/SentryCppHelper/SentryCppHelper.swift" > "$OUTPUT_DIR/payload-hashes.txt"
python3 -c 'import json,sys; json.dump(dict(zip(["compiled_source_revision","upstream_base","reviewed_receiver_commit","reviewed_caller_commit","artifact_id","dependency_lock_sha256","artifact_path","publication","qualification"],sys.argv[1:])),sys.stdout,indent=2)' \
    "$SOURCE_COMMIT" 4f135c52afeeb1d6937eb93824c7ec1cddcaa372 6282aa518d32d4f8fac913602b7c87ba613762de 4b67ceb57b0e452c473ca900f6a24f3c021f1e24 "$ARTIFACT_ID" "$LOCK_SHA" "$ZIP_PATH" unpublished "Local packaging only; controls and consumer symbols require separate receipts" > "$OUTPUT_DIR/provenance.json"
log_info "Unpublished artifact: $ZIP_PATH"
log_info "SwiftPM checksum: $(cat "$OUTPUT_DIR/swiftpm-checksum.txt")"
