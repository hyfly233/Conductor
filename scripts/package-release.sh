#!/bin/zsh
set -euo pipefail

readonly expected_sing_box_version="1.14.0"
readonly project_root="${0:A:h:h}"
readonly configuration="Release"
readonly derived_data="${project_root}/build/DerivedData"
readonly output_directory="${project_root}/build/release"
readonly sing_box_source="${SING_BOX_BINARY:-/opt/homebrew/bin/sing-box}"
readonly sing_box_license="${SING_BOX_LICENSE:-${sing_box_source:h}/LICENSE}"

if [[ ! -x "${sing_box_source}" ]]; then
  print -u2 "sing-box binary is not executable: ${sing_box_source}"
  exit 1
fi

if [[ ! -f "${sing_box_license}" ]]; then
  print -u2 "sing-box license not found: ${sing_box_license}; set SING_BOX_LICENSE to the upstream LICENSE"
  exit 1
fi

if ! lipo -verify_arch "$(uname -m)" "${sing_box_source}"; then
  print -u2 "sing-box binary does not support the host architecture: $(uname -m)"
  exit 1
fi

actual_version="$(${sing_box_source} version | head -n 1 | sed 's/^sing-box version //')"
if [[ "${actual_version}" != "${expected_sing_box_version}" ]]; then
  print -u2 "expected sing-box ${expected_sing_box_version}, got ${actual_version}"
  exit 1
fi

xcodebuild \
  -project "${project_root}/Conductor.xcodeproj" \
  -scheme Conductor \
  -configuration "${configuration}" \
  -destination 'platform=macOS' \
  -derivedDataPath "${derived_data}" \
  build

app_path="${derived_data}/Build/Products/${configuration}/Conductor.app"
runtime_directory="${app_path}/Contents/Resources/bin"
mkdir -p "${runtime_directory}" "${output_directory}"
install -m 755 "${sing_box_source}" "${runtime_directory}/sing-box"
install -m 644 "${sing_box_license}" "${runtime_directory}/LICENSE"

bundled_version="$(${runtime_directory}/sing-box version | head -n 1 | sed 's/^sing-box version //')"
if [[ "${bundled_version}" != "${expected_sing_box_version}" ]]; then
  print -u2 "bundled sing-box version verification failed"
  exit 1
fi

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "${CODE_SIGN_IDENTITY}" "${runtime_directory}/sing-box"
  codesign --force --deep --options runtime --timestamp --sign "${CODE_SIGN_IDENTITY}" "${app_path}"
  codesign --verify --deep --strict --verbose=2 "${app_path}"
else
  print -u2 "No CODE_SIGN_IDENTITY supplied; archive is for local inspection only and is not a notarized distribution."
fi

archive_name="Conductor-1.0.0-$(uname -m).zip"
ditto -c -k --keepParent "${app_path}" "${output_directory}/${archive_name}"
shasum -a 256 "${output_directory}/${archive_name}"

print "Created ${output_directory}/${archive_name}"
