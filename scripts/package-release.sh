#!/bin/zsh
set -euo pipefail

readonly minimum_sing_box_version="1.14.0"
readonly project_root="${0:A:h:h}"
readonly configuration="Release"
readonly derived_data="${project_root}/build/DerivedData"
readonly output_directory="${project_root}/build/release"
readonly sing_box_source="${SING_BOX_BINARY:-/opt/homebrew/bin/sing-box}"
readonly sing_box_license="${SING_BOX_LICENSE:-${sing_box_source:h}/LICENSE}"
readonly cask_template="${project_root}/Casks/conductor.rb.template"

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
if [[ ! "${actual_version}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  print -u2 "unrecognised sing-box version: ${actual_version}"
  exit 1
fi
if [[ "$(printf '%s\n%s\n' "${minimum_sing_box_version}" "${actual_version}" | sort -V | head -n 1)" != "${minimum_sing_box_version}" ]]; then
  print -u2 "sing-box ${minimum_sing_box_version} or newer is required, got ${actual_version}"
  exit 1
fi

print "Clearing previously compiled asset catalog so the icon check reflects this build"
rm -f "${derived_data}/Build/Products/${configuration}/Conductor.app/Contents/Resources/AppIcon.icns"
rm -f "${derived_data}/Build/Products/${configuration}/Conductor.app/Contents/Resources/Assets.car"

readonly icon_directory="${project_root}/Conductor/Assets.xcassets/AppIcon.appiconset"
readonly icon_manifest="${icon_directory}/Contents.json"
if [[ ! -f "${icon_manifest}" ]]; then
  print -u2 "app icon set not found: ${icon_manifest}"
  exit 1
fi
unbound_slots="$(grep -c '"idiom"' "${icon_manifest}" || true)"
bound_slots="$(grep -c '"filename"' "${icon_manifest}" || true)"
if [[ "${bound_slots}" != "${unbound_slots}" || "${bound_slots}" -eq 0 ]]; then
  print -u2 "app icon set has ${unbound_slots} slots but only ${bound_slots} bound to a file"
  print -u2 "every entry needs a \"filename\"; actool silently compiles an empty catalog otherwise"
  exit 1
fi
missing_icon_files=0
for referenced in ${(f)"$(sed -n 's/.*"filename" *: *"\([^"]*\)".*/\1/p' "${icon_manifest}")"}; do
  if [[ ! -f "${icon_directory}/${referenced}" ]]; then
    print -u2 "app icon file referenced but absent: ${referenced}"
    missing_icon_files=$((missing_icon_files + 1))
  fi
done
if [[ "${missing_icon_files}" -gt 0 ]]; then
  exit 1
fi
build_started_at="$(mktemp)"

xcodebuild \
  -project "${project_root}/Conductor.xcodeproj" \
  -scheme Conductor \
  -configuration "${configuration}" \
  -destination 'platform=macOS' \
  -derivedDataPath "${derived_data}" \
  build

app_path="${derived_data}/Build/Products/${configuration}/Conductor.app"
info_plist="${app_path}/Contents/Info.plist"
runtime_directory="${app_path}/Contents/Resources/bin"
mkdir -p "${runtime_directory}" "${output_directory}"

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
if [[ -z "${app_version}" ]]; then
  print -u2 "could not read CFBundleShortVersionString from ${info_plist}"
  exit 1
fi
if [[ ! "${app_version}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  print -u2 "unrecognised app version: ${app_version}"
  exit 1
fi
if [[ ! -f "${cask_template}" ]]; then
  print -u2 "cask template not found: ${cask_template}"
  exit 1
fi

install -m 755 "${sing_box_source}" "${runtime_directory}/sing-box"
install -m 644 "${sing_box_license}" "${runtime_directory}/LICENSE"

bundled_version="$(${runtime_directory}/sing-box version | head -n 1 | sed 's/^sing-box version //')"
if [[ "${bundled_version}" != "${actual_version}" ]]; then
  print -u2 "bundled sing-box version verification failed: ${bundled_version} != ${actual_version}"
  exit 1
fi

if [[ ! -f "${app_path}/Contents/Resources/AppIcon.icns" ]]; then
  print -u2 "AppIcon.icns missing from the built bundle; check AppIcon.appiconset filenames"
  rm -f "${build_started_at}"
  exit 1
fi
if [[ ! -f "${app_path}/Contents/Resources/Assets.car" ]]; then
  print -u2 "Assets.car missing from the built bundle; the asset catalog compiled to nothing"
  rm -f "${build_started_at}"
  exit 1
fi
if [[ "${app_path}/Contents/Resources/AppIcon.icns" -ot "${build_started_at}" ]]; then
  print -u2 "AppIcon.icns predates this build; the icon check would otherwise pass on a stale artifact"
  rm -f "${build_started_at}"
  exit 1
fi
rm -f "${build_started_at}"

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "${CODE_SIGN_IDENTITY}" "${runtime_directory}/sing-box"
  codesign --force --deep --options runtime --timestamp --sign "${CODE_SIGN_IDENTITY}" "${app_path}"
  print "Signed with ${CODE_SIGN_IDENTITY}"
else
  codesign --force --sign - "${runtime_directory}/sing-box" >/dev/null
  codesign --force --deep --sign - "${app_path}" >/dev/null
  print -u2 "No CODE_SIGN_IDENTITY supplied; ad-hoc signed for local inspection only and not a notarized distribution."
fi

if ! codesign --verify --deep --strict "${app_path}" >/dev/null 2>&1; then
  print -u2 "codesign verification failed after bundling the runtime:"
  codesign --verify --deep --strict --verbose=2 "${app_path}" >&2 || true
  exit 1
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
    print -u2 "NOTARY_PROFILE is set but CODE_SIGN_IDENTITY is not; notarization requires a Developer ID signature"
    exit 1
  fi
  notarize_zip="${output_directory}/Conductor-${app_version}-$(uname -m)-notarize.zip"
  ditto -c -k --keepParent "${app_path}" "${notarize_zip}"
  xcrun notarytool submit "${notarize_zip}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${app_path}"
  xcrun stapler validate "${app_path}"
  rm -f "${notarize_zip}"
  print "Notarized and stapled with profile ${NOTARY_PROFILE}"
fi

archive_name="Conductor-${app_version}-$(uname -m).zip"
ditto -c -k --keepParent "${app_path}" "${output_directory}/${archive_name}"

checksum_file="${output_directory}/SHA256SUMS"
digest="$(shasum -a 256 "${output_directory}/${archive_name}" | cut -d' ' -f1)"
temporary_sums="$(mktemp)"
if [[ -f "${checksum_file}" ]]; then
  grep -v "  ${archive_name}\$" "${checksum_file}" > "${temporary_sums}" || true
fi
print "${digest}  ${archive_name}" >> "${temporary_sums}"
sort -k2 "${temporary_sums}" > "${checksum_file}"
rm -f "${temporary_sums}"

if ! grep -q "^${digest}  ${archive_name}\$" "${checksum_file}"; then
  print -u2 "failed to record ${archive_name} in ${checksum_file}"
  exit 1
fi

cask_version="$(sed -n 's/^  version "\(.*\)"$/\1/p' "${cask_template}" | head -n 1)"
if [[ -z "${cask_version}" ]]; then
  print -u2 "could not read the version from ${cask_template}"
  exit 1
fi
if [[ "${cask_version}" != "${app_version}" ]]; then
  print -u2 "version mismatch: app is ${app_version} but ${cask_template} declares ${cask_version}"
  print -u2 "update MARKETING_VERSION, or the Cask version, so the archive name and the tap agree"
  exit 1
fi

print ""
print "Created ${output_directory}/${archive_name}"
print "SHA-256  ${digest}"
print "Recorded in ${checksum_file}"
print ""
print "Next steps for ${cask_version}:"
print "  1. Repeat on the other architecture so both ZIPs sit in the GitHub release"
print "  2. Paste the matching SHA-256 into ${cask_template} (arm/intel slots)"
print "  3. Copy the finished file to hyfly233/homebrew-conductor Casks/conductor.rb"
