# 🍈 Guava — macOS App Updater

**Guava** is a native macOS desktop application that scans your installed applications, Homebrew packages and developer tools, checks for newer versions, and updates all of them with one button — then deletes whatever it downloaded. Its window is a list of your applications and that one button.

---

## ✨ Features

### ⚡ Update Everything
- **One button** — "Update Everything" (⌘U) updates Homebrew, developer tools and every application, then deletes what it downloaded
- **Scans three places** — installed applications, Homebrew formulae and casks, and the dot entries in your home folder (`~/.oh-my-zsh`, `~/.bun`, `~/.vscode`, …)
- **GitHub Copilot agent** — apps that neither Homebrew nor a vendor updater can update are handed to the GitHub Copilot CLI, which downloads and unpacks the new version; it can use computer use (CUA) for updaters that only have a window
- **Guava installs, not the agent** — every download is checked for the right app, a newer version, a valid signature, the same developer and Apple notarization before it replaces anything
- **Cleans up after itself** — staging folders, mounted disk images, Homebrew's download cache and stray installers in Downloads are removed at the end of every run, even one you stop
- **Shows that it is alive** — the step in progress counts its time, and the log says so when a tool has worked in silence for a minute
- See [How Update Everything Works](#-how-update-everything-works) for the details and the limits

### 📋 One Window
- **The list of your applications** — icon, name and installed version, with the apps that have an update at the top
- **What each row tells you** — 🟠 `installed → latest` when an update is waiting, ✅ when the app is as up to date as it can be on this Mac, a spinner while it is being checked or updated, 🔴 if its last update failed (hover for the reason), and the bare version when the last check could not find out
- **Green when the update is not yours to have** — a newer version that this Mac is not offered, as on a Mac whose organisation decides what it runs, does not keep the app orange; hover over the row to see which version exists and why it is not installed
- **Only what can be updated** — an app that no source offers versions of is left out and named in `~/.guava`; hover over the line above the list to see how many
- **One line above it** — how many apps are listed and how many have an update
- **Two controls** — Update Everything (⌘U) and a button that checks again (⌘R)
- No tabs, filters or per-app buttons, and nothing to configure in the window: every app in the list is updated

### 🔍 Application Scanning
- Recursively discovers installed applications in `/Applications` and `~/Applications`
- **Leaves out what macOS updates itself** — nothing under `/System` is scanned, and Apple apps that arrive with macOS (Safari, for instance) are not listed
- **Leaves out web apps** saved from a browser, which belong to that browser
- **Leaves out what nothing can update** — an in-house tool, for instance, that neither Homebrew nor the App Store knows
- Reads app metadata from `Info.plist` — bundle ID, version (`CFBundleShortVersionString`), display name, and icon
- See [What Is Listed](#-what-is-listed)

### 📡 Smart Version Checking
- **Homebrew Cask Database** — Downloads the full cask catalog (~7,500+ apps) from `formulae.brew.sh` as the primary version source, and downloads it again once it is a few minutes old
- **Matched on what each cask declares** — its token and names, the app bundle it installs, and what its uninstall and zap steps remove. No list of particular apps is built in
- **No guessing between products** — when casks of different products claim the same bundle, the app gets no version from Homebrew rather than another product's
- **iTunes/App Store Lookup API** — Checks Apple's API for App Store apps by bundle ID
- **Token Name Guessing** — Automatically generates candidate cask tokens from app names
- **Intelligent Version Comparison** — Handles edge cases like:
  - Build metadata stripping (`0.4.2+2` → `0.4.2`, `1.0,456` → `1.0`)
  - Version scheme mismatches (e.g., `16.105.3` vs `16.105.26020123` — detects build numbers vs short versions)
  - Bracketed build numbers (`7.2.5 (90525)` is the same release as `7.2.5.90525`)
- **App Store receipts** — Any app carrying a Mac App Store receipt is checked against the App Store, even when a Homebrew cask exists for a direct-download build of the same app

### ⚙️ Configuration & Persistence
- **Self-exclusion** — Guava excludes itself from scan results by bundle ID
- **What it has learned about this Mac** — the apps it leaves out, and the updates that were not on offer here, are kept in `~/.guava`. See [The record in `~/.guava`](#the-record-in-guava)
- **Last check** — the time of the last check is kept in `~/.guava_last_scan` and shown when you hover over the check-again button
- **Update settings** — kept in `UserDefaults`; see [Settings](#settings)

### 🎨 User Interface
- Native **SwiftUI** interface with macOS design language
- A thin **progress line** under the header while versions are being checked
- **App icons** displayed alongside each application
- In a wide window the list stays a narrow column, so a name is never far from its version
- **Progress sheet** for Update Everything — the phase, each item's result, a running clock and the activity log; it can be hidden while the run carries on
- Custom **guava-themed app icon** with update arrow badge
- **Settings window** (⌘,) with an Updates tab for Update Everything and an About tab

### 🚀 One-Click Workflow
- **Update Everything** scans, updates and cleans up in one click
- The list is checked when the app opens, and again whenever you ask (⌘R)
- Re-reads installed versions from disk to detect recently updated apps

---

## 🛠 Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6 toolchain (Swift 5 language mode) |
| UI Framework | SwiftUI (macOS 13+) |
| Build System | Swift Package Manager |
| Version APIs | Homebrew Cask API, iTunes Lookup API |
| Update agent | GitHub Copilot CLI (custom agent, optional computer use) |
| Verification | `codesign`, `spctl`, `pkgutil` |
| Persistence | UserDefaults, and a JSON record in `~/.guava` |
| Reactivity | Combine framework |
| Concurrency | Swift async/await with TaskGroups |
| Tests | Swift Testing (`swift test`) |

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
├── Guava/
│   ├── GuavaApp.swift               # Entry point (window or headless), AppDelegate, Settings
│   ├── Models.swift                 # AppInfo, Homebrew and tool models
│   ├── AppScanner.swift             # Finds the apps in /Applications and ~/Applications
│   ├── VersionChecker.swift         # Multi-source version checking engine
│   ├── CaskCatalog.swift            # Matches an installed app to its Homebrew cask
│   ├── CaskDownload.swift           # Download URL and checksum Homebrew publishes for a cask
│   ├── LocalRecord.swift            # What is kept in ~/.guava: apps left out, updates not on offer
│   ├── UpdateEngine.swift           # Homebrew cask upgrade, App Store Updates page
│   ├── BrewHelper.swift             # Homebrew formulae & casks: listing, upgrade, cleanup
│   ├── DevToolScanner.swift         # Dot-entry scan, self-updating tools, Microsoft AutoUpdate
│   ├── ProcessRunner.swift          # Runs commands with timeouts, cancellation, streamed output
│   ├── UpdateOrchestrator.swift     # The Update Everything pipeline
│   ├── UpdatePlan.swift             # Settings, routing rules, plan, results
│   ├── UpdateEnvironment.swift      # Every side effect of a run, behind one protocol
│   ├── CopilotAgent.swift           # Starts the locked-down Copilot CLI session
│   ├── AgentTask.swift              # The agent's rules, its prompt, and its result file
│   ├── AgentAppUpdater.swift        # Runs the agent for one app and vets what it staged
│   ├── CodeSignVerifier.swift       # Signature, developer and Gatekeeper checks
│   ├── AppInstaller.swift           # Replaces apps, runs packages, quits and reopens apps
│   ├── InstallCleanup.swift         # Staging folders, disk images, caches, Downloads sweep
│   ├── HeadlessCLI.swift            # --scan, --update-all, --dry-run
│   ├── UpdateEverythingView.swift   # The button, the progress sheet, the Updates settings
│   ├── GuavaViewModel.swift         # What the window knows: apps, Homebrew packages, tools
│   └── ContentView.swift            # The window: the list of apps and the one button
└── Tests/GuavaTests/                # Swift Testing suites
```

---

## 🚀 Getting Started

### Prerequisites
- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools with Swift 6.0 or later (`xcode-select --install`)
- Optional: [Homebrew](https://brew.sh), for formulae, casks and the download details Guava hands to the agent
- Optional: the [GitHub Copilot CLI](https://github.com/github/copilot-cli), signed in, for apps nothing else can update (`npm install -g @github/copilot`, then run `copilot` once). Without it those apps are listed and skipped

### Local Configuration

Personal and machine-specific values are kept out of the repository. Copy the template and edit it:

```bash
cp local.config.example local.config
```

| Setting | Purpose |
|---------|---------|
| `BUNDLE_ID` | App bundle identifier (defaults to `com.example.guava`) |
| `COPYRIGHT` | Text shown in the About window |

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

### Tests

```bash
swift test
```

The suite makes no network requests and installs nothing: Homebrew, the Copilot CLI and the administrator prompt are replaced by fakes, and the installer runs against throwaway bundles in a temporary folder.

Two groups only run when asked:

```bash
# Real Copilot CLI sessions that update a throwaway app. Uses premium requests.
GUAVA_E2E_AGENT=1 swift test --filter AgentEndToEndTests

# The same, staging the real update of an installed app and checking it with every
# production check. Nothing is installed.
GUAVA_E2E_AGENT=1 GUAVA_E2E_REAL_APP="/Applications/Example.app" \
    swift test --filter AgentEndToEndTests/stagesRealUpdateWithoutInstalling

# Render the window and the progress sheet to PNG files, without opening a window.
GUAVA_UI_SNAPSHOTS=/tmp/guava-snapshots swift test --filter UISnapshotTests
```

### A note on `@State`

The Command Line Tools do not ship the SwiftUI macro plugin, so `@State` does not compile there. The views use `@StateObject`, `@AppStorage` and `@Binding` instead, which keeps the project buildable without Xcode.

---

## ⚡ How Update Everything Works

**Update Everything** (⌘U, or `--update-all` from a terminal) works through the phases below in order. Whatever has a dependable updater of its own is updated with it. The Copilot agent is used only for the apps that are left.

| Phase | What happens |
|-------|--------------|
| **Scanning** | Checks every application, lists Homebrew's formulae and casks, and looks through the dot entries of your home folder for tools that can update themselves |
| **Homebrew** | `brew update`, then one `brew upgrade` for everything outdated and unpinned |
| **Tools** | Runs each detected tool's own updater |
| **Applications** | Updates each outdated app through the channel it came from |
| **Installing** | Installs the updates that need administrator rights, behind a single password prompt |
| **Cleaning up** | Deletes everything the run downloaded. This also happens when you press Stop |
| **Verifying** | Scans again and reports what really changed |

From a terminal, `--update-all --dry-run` stops after scanning and shows the plan.

### Which updater handles an app

The first rule that matches wins, so an App Store copy is never swapped for the vendor's direct-download build of the same app.

1. **It has a Mac App Store receipt** → the App Store. With [`mas`](https://github.com/mas-cli/mas) installed, `mas upgrade` runs first, with the other tools. For anything still outdated after that, Guava opens the App Store's Updates page and the Copilot agent clicks Update All there through computer use. With computer use turned off, or if the agent cannot finish there, the page is left open and the click is yours. A copy licensed to an organisation is not attempted at all: see [Updates this Mac is not offered](#updates-this-mac-is-not-offered).
2. **It was installed with Homebrew** → `brew upgrade --cask`.
3. **It is registered with Microsoft AutoUpdate** → Microsoft AutoUpdate, which keeps the apps it manages current by itself. See below for how it is driven.
4. **Anything else** → the Copilot agent.

### Tools found behind the dot entries

Guava reads the names of the dot entries at the top of your home folder and looks for the tools below. Entries that only hold configuration, history or caches (`~/.ssh`, `~/.gitconfig`, `~/.zsh_history`, …) have nothing to update and are left alone.

| Dot entry | Tool | Updated with |
|-----------|------|--------------|
| `~/.oh-my-zsh` | Oh My Zsh, and the plugins and themes cloned into `custom/` | `tools/upgrade.sh`, `git pull --ff-only` |
| `~/.bun` | Bun | `bun upgrade` |
| `~/.cargo`, `~/.rustup` | Rust toolchains | `rustup update` |
| `~/.deno` | Deno | `deno upgrade` |
| `~/.claude`, `~/.claude-cli` | Claude Code | `claude update` |
| `~/.copilot` | GitHub Copilot CLI | `copilot update` |
| `~/.vscode` | VS Code extensions | `code --update-extensions` |
| `~/.local` | uv tools, pipx applications, GitHub CLI extensions | `uv tool upgrade --all`, `pipx upgrade-all`, `gh extension upgrade --all` |

Microsoft AutoUpdate and `mas` appear in the same list when they are installed.

Microsoft AutoUpdate is not waited for. `msupdate --install` can sit silent for ten minutes even when it has nothing to install, so Guava first asks `msupdate --list`, which answers in seconds. If nothing is pending the step is over. Otherwise Guava starts the installation and moves on: Microsoft's updater downloads and installs by itself, and updates open apps once you close them.

If a tool fails, its row shows the error it reported and the activity log has its full output. A tool that answered when asked for its version before its update, and no longer does afterwards, is reported as failed as well.

**npm's global packages are not updated.** `npm update -g` moves every global package to whatever its registry tags as `latest`, across major versions, and links every command again. That can replace npm itself, or a tool installed through it, with a release that does not work on your setup, and nothing undoes it. Update those packages yourself.

### The Copilot agent

For each app, Guava starts one non-interactive GitHub Copilot CLI session:

- **Its own folder** — `~/Library/Caches/Guava/staging/run-…/<app>/`, with a custom agent named `guava-updater` written into `.github/agents/` there. Its rules are in `Guava/AgentTask.swift`.
- **Few tools** — a shell, file editing, web fetch and web search, plus computer use if you allow it. Every other tool and MCP server is switched off.
- **Confined** — the CLI refuses shell commands that name a path outside that folder, apart from the system tools in `/usr/bin`, `/usr/sbin`, `/usr/libexec`, `/bin` and `/sbin`. `sudo`, `osascript`, `installer`, `brew` and similar commands are denied. The agent is never given administrator rights.
- **Limited** — an AI credit limit and a time limit per app.

The agent downloads the new version and unpacks it, leaving the `.app` or `.pkg` in its folder with a small result file. It takes the download from the URL and SHA-256 that Homebrew publishes for the app when there is one, otherwise from the app's Sparkle feed or the vendor's own website. For an app that can only update itself, it may operate that app's updater through computer use instead.

A session normally costs one Copilot premium request.

### What Guava checks before installing

Guava does not take the agent's word for anything. A staged application replaces the installed one only if all of this holds:

- it is a real application bundle inside the staging folder
- its bundle identifier is the installed app's
- its version is newer than the installed one
- it runs on this Mac's processor and on this version of macOS
- `codesign --verify --deep --strict` passes
- the same developer team signed it as signed the installed copy (checked whenever the installed copy has one)
- Gatekeeper accepts it (`spctl --assess`), which in practice means a notarized Developer ID build

An installer package must be signed with a Developer ID by the same team as the installed copy and be accepted by Gatekeeper. A package runs its own scripts as an administrator, so when the installed copy is unsigned or ad-hoc signed and there is no team to compare with, a package is not installed at all. If the installed copy's signature cannot be read, the app is not updated. Guava never removes quarantine attributes and never overrides Gatekeeper.

### Installing

- An app you own is swapped in place. The previous copy is kept until the new one is in position and is put back if anything goes wrong.
- Apps owned by root, and installer packages, are queued and installed together at the end behind **one** administrator prompt. The new copy gets the owner the old one had.
- The install step works from a private copy of the download and checks that copy again, so nothing can change it between the check and the installation.
- The installed app is only ever renamed or deleted as a whole, never written into: macOS (App Management) blocks one developer's code from writing inside another developer's installed app.
- A running app is asked to quit, never forced, and reopened afterwards. If it stays open, for example because of unsaved changes, it is left alone and reported.
- An update only counts as installed once the version on disk has changed.

### Cleaning up

At the end of every run, including one you stopped:

- disk images mounted from the staging folder are ejected and the folder is deleted
- `brew cleanup --prune=all -s` empties Homebrew's download cache (and, as it always does, removes old versions of upgraded formulae); any download still in the cache's `downloads` folder is deleted. Only files named the way Homebrew names its downloads are touched
- installers (`.dmg`, `.pkg`, `.mpkg`, `.xip`) that appeared in `~/Downloads` during the run are moved to the Trash
- staging folders left by a run that crashed, or that ended because Guava was quit, are removed the next time Guava starts

### Settings

Open Settings (⌘,) → Updates.

| Setting | Default | Notes |
|---------|---------|-------|
| Use the GitHub Copilot agent for apps nothing else can update | On | When off, those apps are listed and skipped |
| Let the agent control the screen (computer use) | On | Needed for the App Store and for apps that can only update themselves |
| Model | Copilot CLI default | |
| AI credit limit per app | 60 | |
| Time limit per app | 20 min | |
| Quit running apps to update them, then reopen them | On | When off, open apps are reported instead of updated |
| Empty Homebrew's download cache | On | |
| Move installers that appear in Downloads to the Trash | On | macOS asks once whether Guava may look in Downloads. If you say no, nothing there is touched. A dry run never looks |

### From a terminal

```bash
GUAVA=build/Guava.app/Contents/MacOS/Guava
$GUAVA --scan                   # what is installed and what is outdated
$GUAVA --update-all --dry-run   # what Update Everything would do
$GUAVA --update-all             # do it
```

`--update-all` exits with status 0 when nothing failed and nothing needs your attention. `--scan` and `--update-all --dry-run` leave nothing behind: they read `~/.guava` and never write it.

### Limits

- **One password prompt.** macOS requires an administrator to approve replacing an app owned by root or running an installer package. Guava asks once per run, for all of them together. It does not store the password or install a privileged helper.
- **App Management.** If macOS stops Guava from replacing another developer's app, the app is left as it was and reported. Allow Guava under System Settings → Privacy & Security → App Management and run it again.
- **Homebrew casks that need `sudo`** cannot be upgraded unattended. They are reported as needing your password, with the `brew upgrade` command to run in Terminal.
- **The App Store and Microsoft AutoUpdate finish in their own time.** Guava starts them and reports those apps as in progress, unless the new version is already in place when it verifies. An update that has not arrived by then is left with them: the app is shown as up to date until it does arrive or a newer version appears.
- **Computer use is best effort.** It depends on what is on screen and needs macOS's Accessibility and Screen Recording permissions. When it cannot be used, the App Store step and self-updating apps are reported instead of updated.
- **Only notarized builds from the same developer are installed.** An update that fails any check is reported and the installed app is left as it was.
- **An agent session can fail or run out of time.** That app is then reported as failed and left as it was; the rest of the run carries on.
- **Quit Guava and the run ends with it.** Stop ends a run tidily and still cleans up. Quitting, or closing the window, does not: updaters that were already running carry on by themselves, and what was downloaded is only deleted the next time Guava starts.

---

## 🔧 How Version Checking Works

Guava asks these sources, in this order, for the latest version of each app:

1. **An app with a Mac App Store receipt** → the iTunes Lookup API (`itunes.apple.com/lookup?bundleId=...`), and nothing else
2. **The Homebrew cask catalogue** → downloaded in full from `formulae.brew.sh/api/cask.json`. Only casks that put an application on the Mac count; fonts and command-line tools are ignored, whatever they are called. A cask claims an app on what the cask says about itself:
   - it installs a bundle with the app's file name
   - it installs from a package, its uninstall deletes this one bundle (or the folder in `/Applications` that the app is alone in), and its zap step removes files kept under the app's bundle identifier
   - its token or one of its names is the app's name

   A claim on the bundle itself outweighs everything else. After that comes a cask Homebrew installed on this Mac, then one whose zap step carries the app's bundle identifier.
3. **The App Store, by bundle identifier** → for an app no cask settled
4. **Token guessing** → for an app no cask claims at all: the app's name as a cask token (`Sample Editor` → `sample-editor`, `sampleeditor`), also without an ending such as "Desktop" or "Manager"

When the strongest claims still come from several casks:

- **Channels of one product** (`sample` and `sample@esr`) — the channel whose version continues the line the installed copy is on is the app's own, so an extended-support build is compared with its own channel and never moved to the main release. Failing that, the main release comes before a side channel.
- **Different products** — Guava does not guess. A wrong match would compare the app with another product's version, and could have that product's download installed over it, so the app gets no version from Homebrew. The one exception is products that report the same version, where one is plainly an edition of the other (`sample` and `sample-for-teams`).

An app that every source could be asked about, and that none of them knows, has no update source and is left out of the list. When a source could not be reached, nothing is concluded and the app stays where it was.

The version check has no list of particular apps built in: everything above comes from Homebrew's catalogue, the App Store and the app's own bundle.

Version comparison handles real-world quirks:
- Strips build metadata after `,` or `+`
- Folds parenthesized build numbers into the version (`7.2.5 (90525)` → `7.2.5.90525`)
- Detects version scheme mismatches (build numbers >100,000 vs normal segments <1,000)
- Compares semantic version segments numerically

---

## 📝 What Is Listed

Every app in the list is updated by Update Everything. What something else keeps up to date, and what nothing can update, is not listed.

| App | Listed | Updated through |
|-----|--------|-----------------|
| **Third-party app** in `/Applications` or `~/Applications` | Yes | Homebrew, Microsoft AutoUpdate or the Copilot agent |
| **App with a Mac App Store receipt** (`_MASReceipt/receipt`), Apple's own included | Yes | The App Store |
| **App that no source offers versions of**, such as an in-house tool | No, and named in `~/.guava` | — |
| **Apple app without a receipt** (`com.apple.*`, such as Safari), and anything under `/System` | No | macOS updates |
| **Web app saved from a browser** | No | Its browser |
| **Guava itself** | No | — |

### Updates this Mac is not offered

A newer version can exist without this Mac being offered it, typically because an organisation decides which version its Macs run. Guava does not report such an update over and over: the app stays green, and hovering over its row names the version that exists and why it is not installed.

- **A copy licensed to an organisation.** An App Store app whose licence an organisation holds for this Mac gets its updates from that organisation's device management, and the App Store offers its user none. Guava reads this from the app's Spotlight metadata and does not attempt the update.
- **An update that was attempted and did not arrive.** When a run hands an update to the App Store, Homebrew, Microsoft AutoUpdate or the app's own updater, and the installed version is still the same when the run verifies, Guava notes both versions and shows the app as up to date. The note is dropped as soon as the installed version changes, or a version newer than the one that did not arrive appears, and the app is tried again.

An update that failed, or that needs something from you, is not treated this way. It is reported, and tried again on the next run.

### The record in `~/.guava`

What Guava has learned about this Mac is kept in one small JSON file in your home folder:

```json
{
  "held" : [
    {
      "installedVersion" : "1.4.0",
      "latestVersion" : "1.5.0",
      "name" : "Sample",
      "path" : "/Applications/Sample.app"
    }
  ],
  "hidden" : [
    {
      "name" : "In-house Tool",
      "path" : "/Applications/In-house Tool.app"
    }
  ]
}
```

`hidden` holds the apps left out of the list, and `held` the updates this Mac was not offered. Every check brings both up to date, so an app returns to the list by itself once a source for it exists, and deleting the file only makes Guava work it all out again. The file names the apps on your Mac, so it is kept outside the repository, and `.gitignore` excludes it in case a copy ever lands there.

---

## 📄 License

This project is for personal use.
