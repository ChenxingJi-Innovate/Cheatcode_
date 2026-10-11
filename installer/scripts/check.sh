#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Override only for a known incompatible CLT install. No system files are changed.
sdk="${CHEATCODE_BUILD_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macosx13.0")
mkdir -p .build/local
if [[ "${CHEATCODE_CLT_WORKAROUND:-0}" == 1 ]]; then
    sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk
    printf '' > .build/local/empty.modulemap
    python3 - <<'PY'
import json, os
json.dump({'version':0,'roots':[{'type':'file','name':'/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap','external-contents':os.path.abspath('.build/local/empty.modulemap')}]},open('.build/local/overlay.json','w'))
PY
    flags=(-sdk "$sdk" -target "$(uname -m)-apple-macosx13.0" -vfsoverlay "$PWD/.build/local/overlay.json" -Xcc -ivfsoverlay -Xcc "$PWD/.build/local/overlay.json")
fi
swiftc "${flags[@]}" -D DEBUG -emit-library -emit-module -module-name InstallerCore Sources/InstallerCore/*.swift -o .build/local/libInstallerCore.dylib -emit-module-path .build/local/InstallerCore.swiftmodule
swiftc "${flags[@]}" -D DEBUG -I .build/local -L .build/local -lInstallerCore -Xlinker -rpath -Xlinker "$PWD/.build/local" Tests/InstallerCoreTests/*.swift -o .build/local/NativeCoreTests
cp Sources/InstallerCore/Resources/targets.json .build/local/targets.json
cp Sources/InstallerCore/Resources/mcp_clients.json .build/local/mcp_clients.json
.build/local/NativeCoreTests "$@"
