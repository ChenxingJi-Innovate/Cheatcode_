#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-development}"
case "$mode" in development|release) ;; *) echo 'Usage: scripts/build.sh [development|release]' >&2; exit 2;; esac
version="${CHEATCODE_VERSION:-0.1.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'CHEATCODE_VERSION must be a numeric semantic version.' >&2; exit 2; }
arch="$(uname -m)"
if [[ "$mode" == release ]]; then
  [[ "${CHEATCODE_SIGN_IDENTITY:-}" == 'Developer ID Application: '* ]] || { echo 'Release requires CHEATCODE_SIGN_IDENTITY, a Developer ID Application identity.' >&2; exit 2; }
  [[ -n "${CHEATCODE_NOTARY_PROFILE:-}" ]] || { echo 'Release requires CHEATCODE_NOTARY_PROFILE, an existing notarytool Keychain profile.' >&2; exit 2; }
fi
mkdir -p .build dist
work="$(mktemp -d "$PWD/.build/package.XXXXXX")"
completed=0
trap 'if [[ "$mode" == release && "$completed" != 1 ]]; then echo "Incomplete release retained for diagnosis or notarization retry: $work" >&2; else rm -rf "$work"; fi' EXIT
app="$work/Cheatcode Installer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
sdk="${CHEATCODE_BUILD_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
flags=(-sdk "$sdk" -target "$arch-apple-macosx13.0")
if [[ "${CHEATCODE_CLT_WORKAROUND:-0}" == 1 ]]; then
  # Match Swift 5.10 to the installed 14.4 SDK and hide the redundant SwiftBridging
  # declaration in this build's VFS. This changes compiler inputs, not release
  # flags: release still omits DEBUG and requires signing, notarization and Gatekeeper.
  # No installed compiler or system file is modified.
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk
  touch "$work/empty.modulemap"
  python3 - "$work" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
(p / 'overlay.json').write_text(json.dumps({'version': 0, 'roots': [{'type': 'file', 'name': '/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap', 'external-contents': str(p / 'empty.modulemap')}]}))
PY
  flags=(-sdk "$sdk" -target "$arch-apple-macosx13.0" -vfsoverlay "$work/overlay.json" -Xcc -ivfsoverlay -Xcc "$work/overlay.json")
fi
if [[ "$mode" == development ]]; then flags+=(-D DEBUG); else flags+=(-O); fi
swiftc "${flags[@]}" -emit-library -emit-module -module-name InstallerCore Sources/InstallerCore/*.swift \
  -o "$app/Contents/Frameworks/libInstallerCore.dylib" -emit-module-path "$work/InstallerCore.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/libInstallerCore.dylib'
swiftc "${flags[@]}" -parse-as-library -I "$work" -L "$app/Contents/Frameworks" -lInstallerCore \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' Sources/CheatcodeInstaller/*.swift \
  -o "$app/Contents/MacOS/CheatcodeInstaller"
cp Sources/InstallerCore/Resources/targets.json "$app/Contents/Resources/targets.json"
cp Sources/InstallerCore/Resources/mcp_clients.json "$app/Contents/Resources/mcp_clients.json"
python3 - "$app" "$version" "$mode" <<'PY'
import plistlib, sys
from pathlib import Path
app, version, mode = sys.argv[1:]
info = dict(CFBundleName='Cheatcode Installer', CFBundleDisplayName='Cheatcode Installer',
            CFBundleIdentifier='com.cheatcodehq.installer', CFBundleExecutable='CheatcodeInstaller',
            CFBundlePackageType='APPL', CFBundleShortVersionString=version, CFBundleVersion=version,
            LSMinimumSystemVersion='13.0', NSHighResolutionCapable=True,
            CheatcodeBuildMode=mode,
            CFBundleURLTypes=[dict(CFBundleURLName='Cheatcode install link', CFBundleURLSchemes=['cheatcode'])])
with (Path(app) / 'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
PY
if [[ "$mode" == development ]]; then
  codesign --force --sign - "$app/Contents/Frameworks/libInstallerCore.dylib"
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$CHEATCODE_SIGN_IDENTITY" "$app/Contents/Frameworks/libInstallerCore.dylib"
  codesign --force --options runtime --timestamp --sign "$CHEATCODE_SIGN_IDENTITY" "$app"
  ditto -c -k --keepParent "$app" "$work/notarize.zip"
  xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$CHEATCODE_NOTARY_PROFILE" --wait --timeout 5m
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose "$app"
fi
codesign --verify --deep --strict "$app"
artifact="Cheatcode-Installer-$version-$arch-$mode"
ditto -c -k --keepParent "$app" "dist/$artifact.zip"
# Preserve earlier build artifacts under versioned names.
ditto "$app" "dist/$artifact.app"
completed=1
echo "$PWD/dist/$artifact.app"
echo "$PWD/dist/$artifact.zip"
[[ "$mode" != development ]] || echo 'Development build only. Ad hoc signed, not notarized, not for public download.'
