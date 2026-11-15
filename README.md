# 🍈 Guava — macOS App Updater

**Guava** is a native macOS desktop application that scans all installed applications, checks for newer versions via public APIs, and helps you keep everything up to date — all from a single, clean interface.

---

## ✨ Features

### 🔍 Application Scanning
- Recursively discovers installed applications from `/Applications`, `~/Applications`, `/System/Applications`, and `/System/Library/CoreServices/Applications`
- Treats apps under macOS-managed system locations as macOS Update apps, including less-visible utilities such as Keychain Access and Archive Utility
- Reads app metadata from `Info.plist` — bundle ID, version (`CFBundleShortVersionString`), display name, and icon
- Detects **80+** applications on a typical macOS system
- Classifies apps into categories: third-party, Apple App Store, and macOS system apps

### 📡 Smart Version Checking
- **Homebrew Cask Database** — Downloads the full cask catalog (~7,500+ apps) from `formulae.brew.sh` as the primary version source
- **iTunes/App Store Lookup API** — Checks Apple's API for App Store apps by bundle ID
- **Manual Bundle ID Mapping** — 35+ hard-to-match apps (Adobe Acrobat, VS Code, Microsoft Office, Docker, etc.) mapped to their Homebrew cask tokens
- **Token Name Guessing** — Automatically generates candidate cask tokens from app names
- **Intelligent Version Comparison** — Handles edge cases like:
  - Build metadata stripping (`0.4.2+2` → `0.4.2`, `1.0,456` → `1.0`)
  - Version scheme mismatches (e.g., `16.105.3` vs `16.105.26020123` — detects build numbers vs short versions)

### 🔄 Update Actions
- **Per-app check** — Refresh button (↻) on each app to re-check its latest version individually
- **Auto-update via Homebrew** — "Update" button for apps installed through Homebrew casks
- **App Store redirect** — Opens the macOS App Store Updates tab for App Store apps
- **Web search fallback** — "Get Update" button opens a browser search for manual download apps
- **Version re-read** — After updating, re-reads the installed version from disk to confirm the update

### 📋 Three-Tab Interface

#### Applications Tab
- Lists all third-party and App Store apps with columns: Application, Installed Version, Latest Version, Status, Action
- **Filters**: All | Updates Available | Up to Date | App Store | Brew
- **Brew view** — Lists Homebrew itself and every explicitly installed cask with installed/latest versions and update status
- **Brew updates** — Upgrade casks individually or run Update All for every unpinned outdated cask
- **Interactive authentication** — Opens Terminal when Homebrew reports that sudo, credentials, or Azure login is required
- **Search bar** — Filter apps by name in real-time
- **Empty state** — Helpful message when search or filter yields no results
- **Status indicators**: ✅ Up to Date, 🟠 Update Ready, ⏳ Checking…, 🔴 Error
- **App Store badge** — Blue badge on Apple App Store apps
- **Hide button** — Eye icon to move any app to the Hidden tab
- **Sticky header** — Column headers stay pinned while scrolling

#### Hidden Apps Tab
- Shows manually hidden apps, macOS system apps, and Edge-installed web apps
- **Filters**: All | Hidden | macOS Native | Edge Apps
- **Edge Apps** — Automatically grouped under Hidden Apps and excluded from update checks
- **Badges**: 🟠 "Hidden" (manually hidden) | ⚪ "macOS Update" (system apps)
- **Unhide button** — "Show" button to restore manually hidden apps to the Applications tab
- **Search bar** — Filter hidden apps by name
- **Empty state** — Distinguishes between "no hidden apps" and "no search matches"

#### Temporary Files Tab
- Scans macOS for cache, log, crash report, and temp files that can be safely deleted to reclaim disk space
- **Scanned directories**: `~/Library/Caches`, `~/Library/Logs`, `~/Library/Application Support/CrashReporter`, `/tmp`, `/var/folders`
- **Columns**: File/Folder name, Application, Category, Size, Action
- **Filters**: All | Cache | Logs | Crash Reports | Temp Files
- **Color-coded category badges**: 🔵 Cache, 🟠 Logs, 🔴 Crash Reports, 🟣 Temp Files
- **Individual delete** — Trash button on each item to delete it
- **Critical file protection** — System-critical files (e.g., `com.apple.LaunchServices`, `com.apple.Spotlight`, `com.apple.kernel`) are marked with a 🔴 "System" badge and cannot be deleted
- **Bulk delete** — "Delete All" button removes all filtered items at once (skips critical files)
- **Reclaimable space banner** — Shows total disk space that can be recovered
- **Smart app detection** — Identifies which app each cache/log folder belongs to from bundle identifiers
- **Recursive size calculation** — Accurately computes folder sizes including all nested contents
- **Search bar** — Filter temp files by name or app name
- **Empty state** — Helpful message when search or filter yields no results

### ⚙️ Configuration & Persistence
- **Hidden apps list** — Persisted via `UserDefaults`, survives app restarts
- **Default hidden apps** — "Guava" plus any apps listed in `DEFAULT_HIDDEN_APPS` in your local `local.config`
- **Self-exclusion** — Guava excludes itself from scan results by bundle ID
- **Last scan timestamp** — Persisted and displayed in footer with relative time ("Last scan: 5 minutes ago")
- **Configurable** — Hide/unhide any app with a single click

### 🎨 User Interface
- Native **SwiftUI** interface with macOS design language
- **Segmented tab picker** for switching between Applications, Hidden Apps, and Temporary Files
- **Progress bar** during batch version checking
- **Status bar** with scan status, last scan time, and app counts
- **Alternating row colors** for readability
- **App icons** displayed alongside each application
- Custom **guava-themed app icon** with update arrow badge
- **About window** accessible via Settings menu

### 🚀 One-Click Workflow
- **Check Updates** button performs a full scan + version check in one click
- Auto-runs on app launch
- Re-reads installed versions from disk to detect recently updated apps

---

## 🛠 Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6 toolchain (Swift 5 language mode) |
| UI Framework | SwiftUI (macOS 13+) |
| Build System | Swift Package Manager |
| Version APIs | Homebrew Cask API, iTunes Lookup API |
| Persistence | UserDefaults |
| Reactivity | Combine framework |
| Concurrency | Swift async/await with TaskGroups |

---

## 📁 Project Structure

```
guava/
├── Package.swift                    # Swift Package Manager config
├── build.sh                         # Build script — creates .app bundle
├── local.config.example             # Template for local, gitignored settings
├── Guava.entitlements               # Network access entitlements
├── README.md
├── build/
│   ├── Guava.app/                   # Built application bundle
│   └── AppIcon.icns                 # App icon
└── Guava/
    ├── GuavaApp.swift               # App entry point, AppDelegate, About view
    ├── Models.swift                 # AppInfo, TempFileInfo models with Published properties
    ├── AppScanner.swift             # Scans system-wide, user, and macOS-managed app locations
    ├── VersionChecker.swift         # Multi-source version checking engine
    ├── UpdateEngine.swift           # Homebrew upgrade, App Store & web links
    ├── TempFileScanner.swift        # Scans macOS cache, log & temp directories
    ├── GuavaViewModel.swift         # Main ViewModel — scanning, checking, filtering, temp files
    ├── ContentView.swift            # Main UI — toolbar, app list, hidden list, temp files list
    ├── HiddenAppsManager.swift      # UserDefaults-persisted hidden app list
    └── BrewHelper.swift             # Homebrew cask listing & upgrade helpers
```

---

## 🚀 Getting Started

### Prerequisites
- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools with Swift 6.0 or later (`xcode-select --install`)

### Local Configuration

Personal and machine-specific values are kept out of the repository. Copy the template and edit it:

```bash
cp local.config.example local.config
```

| Setting | Purpose |
|---------|---------|
| `BUNDLE_ID` | App bundle identifier (defaults to `com.example.guava`) |
| `COPYRIGHT` | Text shown in the About window |
| `DEFAULT_HIDDEN_APPS` | App names hidden on first launch (e.g. workplace-managed apps) |

`local.config` is gitignored; `build.sh` writes these values into the app's `Info.plist`.

### Build & Run

```bash
cd guava
bash build.sh
open build/Guava.app
```

The `build.sh` script:
1. Compiles the Swift package in release mode
2. Creates a proper `.app` bundle with `Info.plist` (version is set by `APP_VERSION` in `build.sh`)
3. Copies the app icon and entitlements
4. Outputs `build/Guava.app` ready to launch

### Development Build

```bash
swift build          # Debug build
swift build -c release  # Release build
```

---

## 🔧 How Version Checking Works

Guava uses a multi-source strategy to find the latest version of each app:

1. **Apple App Store apps** → iTunes Lookup API (`itunes.apple.com/lookup?bundleId=...`)
2. **Manual mapping** → 35+ apps with known bundle-ID-to-cask-token mappings (Adobe, Microsoft, JetBrains, etc.)
3. **Homebrew Cask database** → Downloads the full catalog from `formulae.brew.sh/api/cask.json` and matches by:
   - Cask token (e.g., `google-chrome`)
   - Display name array
   - Artifact app filename
4. **Token guessing** → Converts app name to potential cask tokens (`LM Studio` → `lm-studio`, `lmstudio`)
5. **iTunes API fallback** → Searches by bundle ID for any remaining apps

Version comparison handles real-world quirks:
- Strips build metadata after `,` or `+`
- Detects version scheme mismatches (build numbers >100,000 vs normal segments <1,000)
- Compares semantic version segments numerically

---

## 📝 Apple App Classification

| Category | Detection | Shown In | Badge |
|----------|-----------|----------|-------|
| **Third-party apps** | No `com.apple.*` bundle ID | Applications tab | — |
| **App Store apps** | `com.apple.*` + `_MASReceipt/receipt` exists | Applications tab | 🔵 App Store |
| **macOS system apps** | macOS-managed location, or `com.apple.*` without a receipt | Hidden Apps tab | ⚪ macOS Update |
| **Manually hidden** | User clicked hide button | Hidden Apps tab | 🟠 Hidden |

---

## 📄 License

This project is for personal use.
