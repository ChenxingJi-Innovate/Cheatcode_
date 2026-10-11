# Cheatcode Installer

The Mac app behind every Add button on [cheatcodehq.com](https://cheatcodehq.com). macOS 13+, SwiftUI, no
dependencies. Notarized releases are linked from each listing page; this folder is the source.

An on demand helper for the website's Install button. Open a `cheatcode://install`
link, review the package and destination, and confirm. Project installs ask for a folder.
The helper verifies the pinned package before writing files. It never executes package
content and does not need a browser extension, background server or Accessibility access.

A successful file install does not prove that the AI client loaded the skills;
follow the client's restart instructions shown after installation. Doubao synchronizes its
watched folder to the account; removing cloud copies still requires the Doubao app.

If the command line installer already owns a package, remove it with that installer before
using the native helper. The helper deliberately refuses to take over files without a
verifiable native ownership receipt. Native installs include compatible CLI cleanup records.

## MCP servers (0.3.0)

A `cheatcode://mcp?intent=…&api=…` link adds one MCP server to one AI app. The app checks the signed request
(`McpManifest.validate`: only `npx -y <pkg@version>` or `uvx --from <pkg==version> <exe>`, https for hosted servers, a
client that matches the bundled `mcp_clients.json` exactly), shows what will run and where it is written, asks for any
key in a form, and writes one entry into that app's config (`McpWriter`). It never starts the server; the AI app does.
Servers that need Node or uv get the pinned runtime, downloaded once into `~/.cheatcode/runtime` and checked against its
published SHA-256 (`RuntimePin`), so the config names an absolute path and does not depend on what is installed. Hosted
servers in Claude Desktop (and SSE servers in Codex) run through the pinned `mcp-remote` bridge. Before each write the
previous file is copied to `~/.cheatcode/mcp/backups`; receipts in `~/.cheatcode/mcp/receipts` back the Remove buttons on
the app's start screen. A server of the same name that Cheatcode did not add is left alone, and an unreadable config file is
never overwritten. `mcp_clients.json` and `targets.json` are exported from the API's table of AI apps, so the app and the website never disagree on where a client keeps its files.

## Build and check

From `apps/installer` with a compatible Apple Swift toolchain:

```sh
bash scripts/check.sh
bash scripts/build.sh development
```

Artifacts are in ignored `dist/`, with the version, machine architecture and development
status in the filename. The build uses native SwiftUI and the macOS SDK, no downloaded
dependencies. It targets the current architecture, not a universal binary.

If your Command Line Tools and SDK do not match, the scripts can compile against an installed macOS SDK with a
build-local module map instead (`CHEATCODE_CLT_WORKAROUND=1`), without changing system files.

The core checks are an executable harness, also invoked by a SwiftPM test wrapper on a
working toolchain.
Tests use throwaway homes and never install into your clients.
API-generated integration fixtures are checked into the test folder. The PersonaLens archive there is a test
fixture with a placeholder skill; the real PersonaLens skill is not published.

The target catalog (`Resources/targets.json`) comes from the API; regenerate it when the API's table of AI apps changes.

## Signed distribution

An active Apple Developer Program membership, a Developer ID Application identity in
Keychain, a working Xcode toolchain and a `notarytool` Keychain profile are required.
Do not place Apple passwords or signing keys in this repository.

```sh
CHEATCODE_VERSION=0.1.0 \
CHEATCODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
CHEATCODE_NOTARY_PROFILE='cheatcode-notary' \
bash scripts/build.sh release
```

The release script signs the library and app with hardened runtime, submits to Apple,
staples and validates the notarization ticket, then assesses Gatekeeper before producing
the release ZIP. It fails if these steps fail. Build and verify each supported architecture.
Upload only the verified release ZIP, then configure the API with:

- `DESKTOP_INTENT_SECRET`: persistent random secret of at least 32 bytes, shared across API workers.
- `DESKTOP_MACOS_DOWNLOAD_URL`: HTTPS URL of that release ZIP.
- `DESKTOP_MACOS_VERSION`: its version.
- `DESKTOP_MACOS_SIGNED=true`: set only after the release checks above pass.

