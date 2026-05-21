# Phase 1 — Boot the Renamed Fork

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clone Ghostty v1.3.1, extract its macOS Swift shell into `/Users/ekinertac/Code/emux/`, rename to "emux", build libghostty as a vendored xcframework, and verify the renamed app launches with default Ghostty UX intact. **This is the embedding PoC** — the moment we know the toolchain works end-to-end.

**Architecture:** Pure scaffolding. No UI changes, no new emux features. The output is a buildable Xcode project that produces `emux.app`, capable of running `zsh` in a terminal window the same way Ghostty does today. Everything that makes emux *different* (projects, sidebar, editor, file tree) lands in Phase 2+.

**Tech Stack:** Zig 0.15.2 (one-time, to build the libghostty xcframework), Xcode 15+ (Swift 5.9+), macOS 14.0 deployment target. No Swift package dependencies added in this phase.

**Plan scope:** This plan is Phase 1 of 9. Subsequent phases (projects sidebar, project scoping, file tree, editor, scrollback, palette, modifier hints, polish) will be planned individually after this phase ships and is reviewed. Do not pre-plan later phases.

---

## Prerequisites (operator does these before Task 1)

These are manual environment checks. The plan assumes they're satisfied.

- **Xcode installed.** `xcode-select -p` returns a path. Xcode 15 or later.
- **Homebrew installed.** `brew --version` succeeds.
- **Zig 0.15.2 installed.** `zig version` reports exactly `0.15.2`. If a different version is installed, use [`zigup`](https://github.com/marler8997/zigup) to install the exact pin: `zigup fetch 0.15.2 && zigup default 0.15.2`.
- **~3 GB free disk space** for the Ghostty clone + xcframework build (the build itself is in `/tmp`; only the resulting xcframework lives in the repo, ~60–100 MB).
- **Git installed.** `git --version` succeeds.

### Decision needed before starting

This plan uses `com.ekinertac.emux` as the default bundle identifier (derived from the user's email handle). If you want a different owner segment (e.g., `com.yourname.emux`), substitute it consistently throughout the plan. The plan's commands use the literal string `com.ekinertac.emux` — do find-and-replace in this file before starting if you change it.

---

## File map for this phase

Starting state: `/Users/ekinertac/Code/emux/` contains only `docs/superpowers/specs/2026-05-21-emux-design.md` and `docs/superpowers/plans/2026-05-21-phase-1-boot-fork.md` (this file).

After this phase, the project root will contain:

```
/Users/ekinertac/Code/emux/
├── .git/                                  (initialized fresh in Task 14, no Ghostty history)
├── .gitignore                             (NEW — Xcode + macOS artifacts)
├── docs/
│   └── superpowers/
│       ├── specs/2026-05-21-emux-design.md
│       └── plans/2026-05-21-phase-1-boot-fork.md
├── Frameworks/
│   ├── GhosttyKit.xcframework/            (built from Ghostty v1.3.1, vendored binary)
│   └── LIBGHOSTTY_VERSION                 (NEW — contains the string "v1.3.1")
├── scripts/
│   └── build-libghostty.sh                (NEW — operator script to rebuild xcframework)
├── Sources/                               (copied from ghostty/macos/Sources/)
│   ├── App/
│   ├── Ghostty/
│   ├── Helpers/
│   └── Features/                          (with QuickTerminal, Custom App Icon, Update, AppleScript deleted)
├── Assets.xcassets/                       (copied)
├── emux.entitlements                      (renamed from Ghostty.entitlements)
├── emux.xcodeproj/                        (renamed from Ghostty.xcodeproj, internal references updated)
└── build.nu                               (copied — Nix wrapper, retained for parity even though we won't use it directly)
```

Files deleted from the inherited tree:
- `Sources/Features/QuickTerminal/` (entire folder)
- `Sources/Features/Custom App Icon/` (entire folder)
- `Sources/Features/Update/` (entire folder, plus Sparkle package reference)
- `Sources/Features/AppleScript/` (entire folder)
- `Ghostty.sdef` (AppleScript dictionary)

Files modified in this phase:
- `emux.xcodeproj/project.pbxproj` (renames, bundle id, deployment target, xcframework path, removed Sparkle, removed deleted folder refs)
- `Sources/Features/About/AboutView.swift` (add Ghostty/MIT acknowledgement)

---

## Task 1: Verify prerequisites

**Files:** none modified.

- [ ] **Step 1: Verify Xcode is installed and selected.**

Run:
```bash
xcode-select -p
```
Expected output: a path like `/Applications/Xcode.app/Contents/Developer`. If this errors, install Xcode from the App Store and run `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

- [ ] **Step 2: Verify Zig 0.15.2.**

Run:
```bash
zig version
```
Expected output: exactly `0.15.2`. If a different version is reported, install the pinned version:
```bash
# Option A: zigup (recommended)
brew install marler8997/zigup/zigup
zigup fetch 0.15.2
zigup default 0.15.2

# Option B: direct download — see https://ziglang.org/download/
```

- [ ] **Step 3: Verify disk space.**

Run:
```bash
df -h /tmp / | awk 'NR<=3'
```
Expected: at least 3 GB free on both `/tmp` and `/`.

- [ ] **Step 4: Verify git.**

Run:
```bash
git --version
```
Expected: any 2.x version.

---

## Task 2: Clone Ghostty v1.3.1 into a temp workspace

**Files:** none in the emux repo modified; clone lands in `/tmp/ghostty-build/`.

- [ ] **Step 1: Clean any prior temp clone.**

Run:
```bash
rm -rf /tmp/ghostty-build
```

- [ ] **Step 2: Shallow-clone Ghostty at tag v1.3.1.**

Run:
```bash
git clone --depth=1 --branch=v1.3.1 https://github.com/ghostty-org/ghostty /tmp/ghostty-build
```
Expected: clone completes in ~30 seconds, prints "HEAD is now at <sha> ...".

- [ ] **Step 3: Confirm we got the right tag and structure.**

Run:
```bash
cd /tmp/ghostty-build && git describe --tags && ls -d macos/ src/ build.zig build.zig.zon
```
Expected output:
```
v1.3.1
macos/  src/  build.zig  build.zig.zon
```

If `git describe` does not print `v1.3.1`, abort and re-do Step 2.

---

## Task 3: Build the GhosttyKit XCFramework from source

**Files:** none in the emux repo modified; xcframework produced at `/tmp/ghostty-build/macos/GhosttyKit.xcframework`.

- [ ] **Step 1: Run the Zig build with the macOS app emit disabled.**

Run (this takes 10–20 minutes on first run, mostly compiling dependencies):
```bash
cd /tmp/ghostty-build && zig build -Demit-macos-app=false 2>&1 | tail -20
```
Expected: the last lines show the build completing with no errors. The build invokes `xcodebuild -create-xcframework` internally.

- [ ] **Step 2: Verify the xcframework was produced.**

Run:
```bash
ls -la /tmp/ghostty-build/macos/GhosttyKit.xcframework/
```
Expected: a directory containing `Info.plist`, `macos-arm64/`, `macos-x86_64/` (or `macos-arm64_x86_64/` for the universal layout). Both architectures present means the universal build succeeded.

If only one architecture is present, abort and investigate. The Swift app needs the universal build.

---

## Task 4: Bootstrap the emux directory layout

**Files:**
- Create: `/Users/ekinertac/Code/emux/Frameworks/` (directory)
- Create: `/Users/ekinertac/Code/emux/scripts/` (directory)

- [ ] **Step 1: Create the new top-level directories.**

Run:
```bash
mkdir -p /Users/ekinertac/Code/emux/Frameworks
mkdir -p /Users/ekinertac/Code/emux/scripts
```

- [ ] **Step 2: Verify directory state.**

Run:
```bash
ls -la /Users/ekinertac/Code/emux/
```
Expected: `docs/`, `Frameworks/`, `scripts/` directories present, all owned by the current user.

---

## Task 5: Copy Ghostty's macOS Swift shell into emux

**Files:**
- Copy from `/tmp/ghostty-build/macos/*` → `/Users/ekinertac/Code/emux/*`

The copy excludes `macos/GhosttyKit.xcframework` (we'll place it under `Frameworks/` in the next task instead).

- [ ] **Step 1: Copy the Swift sources, asset catalog, entitlements, and Xcode project.**

Run:
```bash
cd /tmp/ghostty-build/macos && \
  cp -R Sources /Users/ekinertac/Code/emux/ && \
  cp -R Assets.xcassets /Users/ekinertac/Code/emux/ && \
  cp Ghostty.entitlements /Users/ekinertac/Code/emux/ && \
  cp -R Ghostty.xcodeproj /Users/ekinertac/Code/emux/ && \
  cp Ghostty.sdef /Users/ekinertac/Code/emux/ && \
  cp build.nu /Users/ekinertac/Code/emux/ 2>/dev/null || true
```
Expected: no errors. `build.nu` may or may not exist depending on tag — the `|| true` keeps the command non-fatal if missing.

- [ ] **Step 2: Verify the copy succeeded.**

Run:
```bash
ls -la /Users/ekinertac/Code/emux/
```
Expected entries (among others): `Sources/`, `Assets.xcassets/`, `Ghostty.entitlements`, `Ghostty.xcodeproj/`, `Ghostty.sdef`, plus the pre-existing `docs/`, `Frameworks/`, `scripts/`.

- [ ] **Step 3: Spot-check the Sources tree.**

Run:
```bash
ls /Users/ekinertac/Code/emux/Sources/
ls /Users/ekinertac/Code/emux/Sources/Features/
```
Expected: `App/`, `Ghostty/`, `Helpers/`, `Features/` under `Sources/`; under `Features/`, you should see `Terminal/`, `Splits/`, `Settings/`, `Projects/` (no — that one's NEW for emux, won't be present yet), and the others that we'll be deleting in Task 9 (`QuickTerminal/`, `Custom App Icon/`, `Update/`, `AppleScript/`).

---

## Task 6: Vendor the XCFramework

**Files:**
- Copy: `/tmp/ghostty-build/macos/GhosttyKit.xcframework` → `/Users/ekinertac/Code/emux/Frameworks/GhosttyKit.xcframework`
- Create: `/Users/ekinertac/Code/emux/Frameworks/LIBGHOSTTY_VERSION`

- [ ] **Step 1: Copy the xcframework into emux/Frameworks/.**

Run:
```bash
cp -R /tmp/ghostty-build/macos/GhosttyKit.xcframework /Users/ekinertac/Code/emux/Frameworks/
```
Expected: no errors. The copy is ~60–100 MB.

- [ ] **Step 2: Write the version pin file.**

Run:
```bash
echo "v1.3.1" > /Users/ekinertac/Code/emux/Frameworks/LIBGHOSTTY_VERSION
```

- [ ] **Step 3: Verify.**

Run:
```bash
ls -la /Users/ekinertac/Code/emux/Frameworks/
cat /Users/ekinertac/Code/emux/Frameworks/LIBGHOSTTY_VERSION
```
Expected: `GhosttyKit.xcframework/` directory and `LIBGHOSTTY_VERSION` file with contents `v1.3.1`.

---

## Task 7: Write the libghostty rebuild script

**Files:**
- Create: `/Users/ekinertac/Code/emux/scripts/build-libghostty.sh`

This script is what operators run later to bump the pinned Ghostty version. It's not exercised in Phase 1 (we already have the xcframework from Task 6) but it must exist so future bumps are reproducible.

- [ ] **Step 1: Write the script.**

Create file `/Users/ekinertac/Code/emux/scripts/build-libghostty.sh` with these exact contents:

```bash
#!/usr/bin/env bash
#
# build-libghostty.sh — rebuild the vendored GhosttyKit.xcframework from a pinned Ghostty tag.
#
# Usage:
#   ./scripts/build-libghostty.sh                # uses the default tag below
#   GHOSTTY_TAG=v1.4.0 ./scripts/build-libghostty.sh   # override
#
# Requires: zig (version per Ghostty's build.zig.zon), git, xcode-select.
# Writes:
#   Frameworks/GhosttyKit.xcframework  (replaces any existing copy)
#   Frameworks/LIBGHOSTTY_VERSION      (records the tag built)
#
set -euo pipefail

GHOSTTY_TAG="${GHOSTTY_TAG:-v1.3.1}"
WORKDIR="$(mktemp -d)"
EMUX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Cloning ghostty-org/ghostty @ $GHOSTTY_TAG into $WORKDIR ..."
git clone --depth=1 --branch="$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty "$WORKDIR/ghostty"

echo "==> Building XCFramework (this can take 10-20 minutes) ..."
cd "$WORKDIR/ghostty"
zig build -Demit-macos-app=false

echo "==> Vendoring xcframework into $EMUX_ROOT/Frameworks/ ..."
rm -rf "$EMUX_ROOT/Frameworks/GhosttyKit.xcframework"
cp -R macos/GhosttyKit.xcframework "$EMUX_ROOT/Frameworks/"
echo "$GHOSTTY_TAG" > "$EMUX_ROOT/Frameworks/LIBGHOSTTY_VERSION"

echo "==> Done. Pinned to $GHOSTTY_TAG."
echo "    Commit the changes in Frameworks/ to record the bump."
```

- [ ] **Step 2: Make the script executable.**

Run:
```bash
chmod +x /Users/ekinertac/Code/emux/scripts/build-libghostty.sh
```

- [ ] **Step 3: Verify.**

Run:
```bash
ls -la /Users/ekinertac/Code/emux/scripts/build-libghostty.sh
```
Expected: executable bit set (`-rwxr-xr-x`).

---

## Task 8: Open the project in Xcode and rename it

**Files:**
- Modify: `/Users/ekinertac/Code/emux/Ghostty.xcodeproj/` → `/Users/ekinertac/Code/emux/emux.xcodeproj/` (and all internal references updated)
- Modify: `/Users/ekinertac/Code/emux/Ghostty.entitlements` → `/Users/ekinertac/Code/emux/emux.entitlements`

This task uses Xcode's interactive **Rename Project** action because it correctly updates dozens of internal `project.pbxproj` references in one step. A scripted sed-based rename is error-prone for this many references.

- [ ] **Step 1: Open the project in Xcode.**

Run:
```bash
open /Users/ekinertac/Code/emux/Ghostty.xcodeproj
```
Expected: Xcode opens the project.

- [ ] **Step 2: Rename the project to "emux".**

In Xcode:
1. Click the project root in the Project Navigator (top entry, labeled "Ghostty").
2. In the Inspector on the right (or by pressing Return on the name in the navigator), edit the name from `Ghostty` to `emux`.
3. Xcode will show a "Rename Project Content" dialog listing all files/targets that contain the string "Ghostty". **Carefully review the list.** Items to rename:
   - The project itself (Ghostty → emux)
   - The target (Ghostty → emux)
   - The scheme (Ghostty → emux)
   - The entitlements file (Ghostty.entitlements → emux.entitlements)
   
   Items to **NOT** rename (uncheck them):
   - `Ghostty.app` reference (rename is fine, but verify)
   - Any references inside `Sources/Ghostty/` — that's the libghostty wrapper subsystem, the name "Ghostty" there refers to the upstream library and should stay
   - `Ghostty.sdef` — we'll delete it in Task 10 anyway, but don't rename it here
   - Any source file named `Ghostty*.swift` (these are the libghostty wrapper classes; keep their names)
   - The Clang module name `GhosttyKit` (in any `module.modulemap` or bridging code)

4. Click **Rename**. Xcode closes/reopens the project.

- [ ] **Step 3: Quit Xcode.**

Use `Cmd-Q` or `osascript -e 'quit app "Xcode"'`.

- [ ] **Step 4: Verify the rename on disk.**

Run:
```bash
ls -la /Users/ekinertac/Code/emux/ | grep -E '\.xcodeproj|\.entitlements'
```
Expected:
```
emux.xcodeproj
emux.entitlements
```
No `Ghostty.xcodeproj` or `Ghostty.entitlements` should remain. (If they do, the Xcode rename didn't take — re-open in Xcode and retry.)

- [ ] **Step 5: Verify Sources/Ghostty/ was NOT renamed.**

Run:
```bash
ls /Users/ekinertac/Code/emux/Sources/Ghostty/ | head -5
```
Expected: the directory still exists with its Swift files (Ghostty.App.swift, etc.). The library-wrapper subsystem keeps the "Ghostty" name.

---

## Task 9: Update bundle id, app name, deployment target, xcframework path

**Files:**
- Modify: `/Users/ekinertac/Code/emux/emux.xcodeproj/project.pbxproj`

This task uses Xcode's Build Settings UI to make four targeted changes. Direct pbxproj editing is risky.

- [ ] **Step 1: Re-open the project in Xcode.**

Run:
```bash
open /Users/ekinertac/Code/emux/emux.xcodeproj
```

- [ ] **Step 2: Change the bundle identifier.**

1. Select the `emux` project root in the navigator.
2. Select the `emux` target.
3. Open the **Signing & Capabilities** tab.
4. Change `Bundle Identifier` from `com.mitchellh.ghostty` to `com.ekinertac.emux`.
   (If the user chose a different owner segment, substitute here.)

- [ ] **Step 3: Set the deployment target to macOS 14.0.**

1. With the `emux` target still selected, open the **General** tab.
2. Under **Minimum Deployments**, change `macOS` to `14.0` (it's currently 13.0 or 13.1).

- [ ] **Step 4: Update the XCFramework reference path.**

The project was referencing `GhosttyKit.xcframework` as a sibling of the old `Ghostty.xcodeproj`. Now that `emux.xcodeproj` is at the repo root and the xcframework lives in `Frameworks/`, the reference must be updated.

1. In the Project Navigator, find `GhosttyKit.xcframework` (usually under `Frameworks` group or directly under the project).
2. Right-click it → **Delete** → **Remove Reference** (do NOT delete the file from disk).
3. Drag `Frameworks/GhosttyKit.xcframework` from Finder (or use **File → Add Files to "emux"...**) and add it back. Ensure:
   - **Copy items if needed** is **unchecked** (we want to reference, not duplicate).
   - **Add to targets: emux** is **checked**.
4. After adding, select the xcframework in the navigator and verify in the Inspector that the path is shown as `Frameworks/GhosttyKit.xcframework` and the **Location** is "Relative to Project".

- [ ] **Step 5: Verify the build target's "Embed Frameworks" includes the xcframework.**

1. Target `emux` → **General** tab → **Frameworks, Libraries, and Embedded Content**.
2. Confirm `GhosttyKit.xcframework` appears with **Embed & Sign** selected. If it shows "Do Not Embed", change to "Embed & Sign".

- [ ] **Step 6: Save and quit Xcode.**

Use `Cmd-S` then `Cmd-Q`.

---

## Task 10: Remove non-v1 features

**Files:**
- Delete: `/Users/ekinertac/Code/emux/Sources/Features/QuickTerminal/` (entire folder)
- Delete: `/Users/ekinertac/Code/emux/Sources/Features/Custom App Icon/` (entire folder)
- Delete: `/Users/ekinertac/Code/emux/Sources/Features/Update/` (entire folder)
- Delete: `/Users/ekinertac/Code/emux/Sources/Features/AppleScript/` (entire folder)
- Delete: `/Users/ekinertac/Code/emux/Ghostty.sdef`
- Modify: `/Users/ekinertac/Code/emux/emux.xcodeproj/project.pbxproj` (remove references to deleted files)

We delete on disk first, then remove the now-broken file references from the Xcode project. (Doing it via Xcode's "Move to Trash" handles both at once and is safer.)

- [ ] **Step 1: Re-open the project in Xcode.**

Run:
```bash
open /Users/ekinertac/Code/emux/emux.xcodeproj
```

- [ ] **Step 2: Delete each non-v1 feature folder via Xcode.**

For each of these folders in the Project Navigator:
- `Sources/Features/QuickTerminal/`
- `Sources/Features/Custom App Icon/`
- `Sources/Features/Update/`
- `Sources/Features/AppleScript/`

Right-click the folder → **Delete** → **Move to Trash**. This both removes the reference from the project and deletes the files from disk.

- [ ] **Step 3: Delete the AppleScript .sdef.**

In the Project Navigator, find `Ghostty.sdef` (top-level file). Right-click → **Delete** → **Move to Trash**.

- [ ] **Step 4: Verify on disk.**

Run:
```bash
ls /Users/ekinertac/Code/emux/Sources/Features/ | grep -E 'QuickTerminal|Custom App Icon|Update|AppleScript' || echo "all deleted"
ls /Users/ekinertac/Code/emux/Ghostty.sdef 2>&1 | grep -E "No such file" && echo "sdef deleted"
```
Expected: both echo lines print ("all deleted" and "sdef deleted").

---

## Task 11: Remove the Sparkle dependency

**Files:**
- Modify: `/Users/ekinertac/Code/emux/emux.xcodeproj/project.pbxproj` (remove Sparkle package reference)

When we deleted `Sources/Features/Update/` in Task 10, the Swift code that used Sparkle is gone, but the **package dependency** itself is still listed in the project. Building will fail until we remove it.

- [ ] **Step 1: Open the project in Xcode (or keep it open from Task 10).**

```bash
open /Users/ekinertac/Code/emux/emux.xcodeproj
```

- [ ] **Step 2: Remove the Sparkle package dependency.**

1. Select the `emux` project root in the navigator.
2. Open the **Package Dependencies** tab.
3. Select `Sparkle` in the list.
4. Click the `-` button at the bottom of the list to remove it.
5. Xcode may prompt about cached packages; confirm removal.

- [ ] **Step 3: Verify Sparkle is gone from Linked Frameworks.**

1. Target `emux` → **General** → **Frameworks, Libraries, and Embedded Content**.
2. `Sparkle` should not appear. If it does, click `-` to remove it.

- [ ] **Step 4: Save Xcode.**

`Cmd-S`.

---

## Task 12: Initial build sanity check

**Files:** none modified.

- [ ] **Step 1: Build the project from the command line.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild \
    -project emux.xcodeproj \
    -scheme emux \
    -configuration Debug \
    -destination 'platform=macOS' \
    build 2>&1 | tail -30
```

Expected: the last lines contain `** BUILD SUCCEEDED **`.

**If the build fails**, the most likely causes (in order):

1. **Missing source files** referenced by the deleted features. Look for errors like `cannot find type 'QuickTerminalController' in scope` or similar. The fix is to find the orphan reference (search the source tree for the missing symbol) and either delete the consuming code or comment it out (preferred: delete — we won't bring those features back in v1). Common spots: `AppDelegate.swift` initializes/references QuickTerminal, Update, and AppleScript subsystems. Delete those initialization lines.

2. **Sparkle still referenced** in source. Search:
   ```bash
   grep -rn 'import Sparkle\|SPUUpdater\|SUUpdater' /Users/ekinertac/Code/emux/Sources/
   ```
   Delete any remaining imports/uses.

3. **xcframework path wrong**. Re-do Task 9 Step 4.

4. **Deployment target mismatch** between project and target settings. In **Build Settings** for the project (not just target), search for `MACOSX_DEPLOYMENT_TARGET` and confirm it's `14.0`.

Iterate until `BUILD SUCCEEDED`.

- [ ] **Step 2: Confirm the built app product exists.**

Run:
```bash
find /Users/ekinertac/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d 2>/dev/null | head -3
```
Expected: one or more paths to the built `emux.app`. Note the most recent one (highest in the list).

---

## Task 13: Launch the app and verify it works

**Files:** none modified.

- [ ] **Step 1: Launch the built app.**

Run:
```bash
APP_PATH=$(find /Users/ekinertac/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d 2>/dev/null | head -1)
echo "Launching: $APP_PATH"
open "$APP_PATH"
```
Expected: the app launches. A terminal window appears (default Ghostty behavior — emux currently inherits this).

- [ ] **Step 2: Verify the app bundle identity in macOS.**

While the app is running, in a separate terminal:
```bash
osascript -e 'tell application "System Events" to get bundle identifier of (first application process whose name is "emux")'
```
Expected output: `com.ekinertac.emux` (or your chosen owner segment).

If it shows `com.mitchellh.ghostty`, the bundle id change in Task 9 didn't take — quit the app, redo Task 9 Step 2, rebuild (Task 12), relaunch.

- [ ] **Step 3: Manual smoke check in the running app.**

In the emux terminal window:
- Type `echo hello`. Expected: prints `hello`.
- Type `pwd`. Expected: prints a path (your home directory or wherever it launched).
- Press `Cmd-T`. Expected: a new tab opens (native NSWindow tabbing — we'll replace this in Phase 3, but for now it should work as Ghostty does).
- Press `Cmd-D`. Expected: a split appears in the current pane (Ghostty default keybinding).
- Press `Cmd-,`. Expected: Settings window opens.

- [ ] **Step 4: Quit the app.**

`Cmd-Q`.

This task is the **embedding PoC milestone**: we have proven that the toolchain (Zig build → xcframework → vendored binary → Swift app → renamed bundle) all works end-to-end.

---

## Task 14: Update the About sheet to credit Ghostty

**Files:**
- Modify: `/Users/ekinertac/Code/emux/Sources/Features/About/AboutView.swift`

The MIT license requires we preserve the upstream copyright notice and acknowledge attribution. The About sheet is the standard place.

- [ ] **Step 1: Read the existing AboutView.swift.**

Run:
```bash
wc -l /Users/ekinertac/Code/emux/Sources/Features/About/AboutView.swift
head -50 /Users/ekinertac/Code/emux/Sources/Features/About/AboutView.swift
```
Expected: the file is around 100–150 lines; the head shows the SwiftUI view declaration including a `VStack` or similar with the app name and version.

- [ ] **Step 2: Locate the section that renders the app description / credits.**

Look for a section near the bottom of the `VStack` that contains static text like `"Terminal emulator"` or copyright text. This is where we'll add the Ghostty acknowledgement.

- [ ] **Step 3: Insert the Ghostty acknowledgement.**

Add the following SwiftUI block immediately after the existing app description / before the closing brace of the main VStack. The exact insertion point depends on the file's structure; the rule is: it should appear visually below the app name/version block.

Code to add:

```swift
Divider()
    .padding(.vertical, 8)

VStack(alignment: .leading, spacing: 4) {
    Text("Acknowledgements")
        .font(.headline)
    Text("emux is a fork of Ghostty's macOS app shell, with the libghostty terminal core consumed as a library.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    Text("Ghostty is © Mitchell Hashimoto and Ghostty contributors, MIT licensed.\nhttps://github.com/ghostty-org/ghostty")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
}
.padding(.horizontal)
.frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 4: Build to confirm the change compiles.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  xcodebuild -project emux.xcodeproj -scheme emux -configuration Debug \
    -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Launch and verify the About sheet.**

Run:
```bash
APP_PATH=$(find /Users/ekinertac/Library/Developer/Xcode/DerivedData -name 'emux.app' -type d 2>/dev/null | head -1)
open "$APP_PATH"
```
Then, in the running app, use the menu **emux → About emux** (or the equivalent menu item). Confirm the Acknowledgements section appears with the Ghostty credit and link.

Quit the app (`Cmd-Q`).

---

## Task 15: Initialize git and create the first commit

**Files:**
- Create: `/Users/ekinertac/Code/emux/.gitignore`
- Initialize: git repo in `/Users/ekinertac/Code/emux/`

- [ ] **Step 1: Write the .gitignore.**

Create `/Users/ekinertac/Code/emux/.gitignore` with the following contents:

```gitignore
# Xcode user-specific data
xcuserdata/
*.xcuserstate
*.xcuserdatad/

# Build artifacts
build/
DerivedData/
*.xcarchive

# macOS metadata
.DS_Store

# Swift Package Manager local state (we have no SPM packages in Phase 1, but harmless)
.swiftpm/
.build/
Package.resolved

# Temporary files
*.swp
*.tmp

# IDE files
.vscode/
.idea/
```

- [ ] **Step 2: Initialize the git repo.**

Run:
```bash
cd /Users/ekinertac/Code/emux && git init
```
Expected: `Initialized empty Git repository in /Users/ekinertac/Code/emux/.git/`.

- [ ] **Step 3: Verify what git sees.**

Run:
```bash
cd /Users/ekinertac/Code/emux && git status --short | head -30
```
Expected: a list of untracked files including `Sources/`, `emux.xcodeproj/`, `Frameworks/`, `scripts/`, `docs/`, `.gitignore`, `Assets.xcassets/`, `emux.entitlements`. Should NOT include `*.xcuserstate` or `DerivedData/`.

- [ ] **Step 4: Stage everything except the xcframework (we'll add it explicitly to be careful about size).**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  git add .gitignore docs/ Sources/ scripts/ Assets.xcassets emux.entitlements emux.xcodeproj && \
  git add Frameworks/LIBGHOSTTY_VERSION Frameworks/GhosttyKit.xcframework && \
  git status --short | wc -l
```
Expected: a count of staged files (likely several hundred — most of `Sources/` plus the xcframework contents).

- [ ] **Step 5: Verify size before committing.**

Run:
```bash
cd /Users/ekinertac/Code/emux && du -sh Frameworks/GhosttyKit.xcframework
```
Expected: 50–120 MB. This is committed as a regular binary blob (no LFS in Phase 1 — revisit if repo size becomes painful).

- [ ] **Step 6: Create the initial commit.**

Run:
```bash
cd /Users/ekinertac/Code/emux && \
  git commit -m "$(cat <<'EOF'
Initial fork from Ghostty v1.3.1

emux is a detached fork of Ghostty's macOS Swift app shell. The terminal
core (libghostty) is consumed as a pinned, vendored XCFramework built from
Ghostty's v1.3.1 release.

This commit establishes the scaffolding only — no emux-specific features
yet. The app launches as "emux" with default Ghostty UX intact.

Removed from upstream: QuickTerminal, Custom App Icon, Update (Sparkle),
AppleScript.

Acknowledgement: Ghostty is MIT licensed, © Mitchell Hashimoto and Ghostty
contributors. See About sheet and ./Frameworks/LIBGHOSTTY_VERSION.
EOF
)"
```
Expected: a commit summary printed.

- [ ] **Step 7: Verify the commit.**

Run:
```bash
cd /Users/ekinertac/Code/emux && git log --oneline -1
```
Expected: one commit with the subject `Initial fork from Ghostty v1.3.1`.

---

## Phase 1 done — verification summary

Before declaring Phase 1 complete, all of these must be true:

- [ ] `xcodebuild -project emux.xcodeproj -scheme emux build` succeeds
- [ ] The built `emux.app` launches and shows a terminal window
- [ ] `osascript` reports the bundle id as `com.ekinertac.emux`
- [ ] `Cmd-T` opens a new tab, `Cmd-D` creates a split, `Cmd-,` opens settings
- [ ] The About sheet shows the Ghostty MIT acknowledgement
- [ ] `git log --oneline` shows the initial commit
- [ ] `Frameworks/LIBGHOSTTY_VERSION` contains `v1.3.1`
- [ ] `Sources/Features/QuickTerminal/`, `Custom App Icon/`, `Update/`, `AppleScript/`, and `Ghostty.sdef` are gone

When all of the above pass, **pause and demo to the user before starting Phase 2 planning.** The user will iterate on the UX feel of the inherited Ghostty UI before we start replacing it.
