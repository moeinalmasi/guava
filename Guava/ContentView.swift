import SwiftUI

/// Main content view showing the list of applications
struct ContentView: View {
    @StateObject private var viewModel = GuavaViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar + toolbar
            toolbarView
            
            Divider()
            
            // Progress bar
            if viewModel.isCheckingAll {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            
            // Content based on tab
            if viewModel.isScanning && viewModel.selectedTab != .tempFiles {
                scanningView
            } else if viewModel.selectedTab == .apps {
                if viewModel.filterMode == .brew {
                    brewListView
                } else if viewModel.apps.isEmpty {
                    emptyStateView
                } else {
                    appListView
                }
            } else if viewModel.selectedTab == .hidden {
                hiddenListView
            } else {
                tempFilesListView
            }
            
            Divider()
            
            statusBarView
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if !viewModel.isScanning && !viewModel.isCheckingAll {
                viewModel.checkForUpdates(persistTimestamp: false)
            }
        }
        .alert(item: $viewModel.brewAuthenticationRequest) { request in
            Alert(
                title: Text(
                    request.requiresAzureLogin
                        ? "Azure Login Required"
                        : "Authentication Required"
                ),
                message: Text(
                    "\(request.errorMessage)\n\nOpen Terminal to authenticate and retry the update."
                ),
                primaryButton: .default(Text("Open Terminal")) {
                    viewModel.openInteractiveBrewUpgrade(request)
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    var toolbarView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Tab picker
                Picker("", selection: $viewModel.selectedTab) {
                    ForEach(GuavaViewModel.Tab.allCases, id: \.self) { tab in
                        switch tab {
                        case .apps:
                            Text("Applications (\(viewModel.apps.count))").tag(tab)
                        case .hidden:
                            Text("Hidden (\(viewModel.hiddenApps.count))").tag(tab)
                        case .tempFiles:
                            Text("Temp Files (\(viewModel.tempFiles.count))").tag(tab)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search applications...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                    if !viewModel.searchText.isEmpty {
                        Button(action: { viewModel.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .frame(maxWidth: 250)
                
                // Filter pickers — each tab gets its own, toggled by opacity
                ZStack {
                    Picker("", selection: $viewModel.filterMode) {
                        ForEach(GuavaViewModel.FilterMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 460)
                    .opacity(viewModel.selectedTab == .apps ? 1 : 0)
                    .disabled(viewModel.selectedTab != .apps)
                    
                    Picker("", selection: $viewModel.hiddenFilterMode) {
                        ForEach(GuavaViewModel.HiddenFilterMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 460)
                    .opacity(viewModel.selectedTab == .hidden ? 1 : 0)
                    .disabled(viewModel.selectedTab != .hidden)
                    
                    Picker("", selection: $viewModel.tempFileFilterMode) {
                        Text("All").tag(nil as TempFileCategory?)
                        ForEach(TempFileCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat as TempFileCategory?)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 460)
                    .opacity(viewModel.selectedTab == .tempFiles ? 1 : 0)
                    .disabled(viewModel.selectedTab != .tempFiles)
                }
                .frame(width: 460)
                
                Spacer()
                
                // Action buttons — per tab
                if viewModel.selectedTab == .apps && viewModel.filterMode == .brew {
                    HStack(spacing: 8) {
                        Button(action: { viewModel.refreshBrewUpdates() }) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isScanningBrew || viewModel.isUpdatingAllBrew)

                        Button(action: { viewModel.updateAllBrewCasks() }) {
                            Label("Update All", systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !viewModel.brewUpdates.contains { $0.canUpdate } ||
                            viewModel.isScanningBrew ||
                            viewModel.isUpdatingAllBrew
                        )
                    }
                } else if viewModel.selectedTab == .apps {
                    Button(action: { viewModel.checkForUpdates() }) {
                        Label("Check Updates", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isScanning || viewModel.isCheckingAll)
                } else if viewModel.selectedTab == .tempFiles {
                    HStack(spacing: 8) {
                        Button(action: { viewModel.scanTempFiles() }) {
                            Label("Scan", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isScanningTempFiles)
                        
                        Button(role: .destructive, action: { viewModel.deleteAllTempFiles() }) {
                            Label("Delete All", systemImage: "trash")
                        }
                        .disabled(viewModel.filteredTempFiles.isEmpty || viewModel.isDeletingAllTempFiles)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    var appListView: some View {
        VStack(spacing: 0) {
            // Sticky header row
            HStack(spacing: 12) {
                Text("Application")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Installed Version")
                    .frame(width: 110, alignment: .center)
                Text("Latest Version")
                    .frame(width: 110, alignment: .center)
                Text("Status")
                    .frame(width: 120, alignment: .center)
                Text("Action")
                    .frame(width: 150, alignment: .center)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            ScrollView {
                if viewModel.filteredApps.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Matching Applications")
                            .font(.title2)
                        Text("No applications match your current search or filter.")
                            .foregroundColor(.secondary)
                        Button("Clear Search") { viewModel.searchText = ""; viewModel.filterMode = .all }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.filteredApps.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 12) {
                        // Icon + name
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "app.fill")
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(app.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    if app.isAppleAppStoreApp {
                                        Text("App Store")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.7))
                                            .cornerRadius(3)
                                    }
                                }
                                if let bid = app.bundleIdentifier {
                                    Text(bid)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        // Installed
                        Text(app.currentVersion)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .frame(width: 110, alignment: .center)
                        
                        // Latest
                        Group {
                            if app.updateStatus == .checking {
                                ProgressView().scaleEffect(0.5)
                            } else if let latest = app.latestVersion {
                                Text(latest)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(app.hasUpdate ? .orange : .green)
                                    .fontWeight(app.hasUpdate ? .bold : .regular)
                                    .lineLimit(1)
                            } else {
                                Text("—")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 110, alignment: .center)
                        
                        // Status
                        Group {
                            switch app.updateStatus {
                            case .upToDate:
                                Label("Up to Date", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            case .updateAvailable:
                                Label("Update Ready", systemImage: "arrow.up.circle.fill")
                                    .foregroundColor(.orange)
                            case .checking:
                                HStack(spacing: 3) {
                                    ProgressView().scaleEffect(0.5)
                                    Text("Checking…").foregroundColor(.secondary)
                                }
                            case .updating:
                                HStack(spacing: 3) {
                                    ProgressView().scaleEffect(0.5)
                                    Text("Updating…").foregroundColor(.blue)
                                }
                            case .error:
                                Label("Error", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .help(app.updateError ?? "")
                            case .unknown:
                                Text("Not Checked").foregroundColor(.secondary)
                            }
                        }
                        .font(.system(size: 11))
                        .frame(width: 120, alignment: .center)
                        
                        // Actions
                        HStack(spacing: 6) {
                            if !app.isUpdating && app.updateStatus != .checking {
                                Button(action: { viewModel.checkSingleApp(app) }) {
                                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                                }
                                .buttonStyle(.borderless)
                                .help("Check for update")
                            }
                            
                            if app.isUpdating {
                                ProgressView().scaleEffect(0.6)
                            } else if app.canAutoUpdate {
                                Button("Update") { viewModel.updateApp(app) }
                                    .buttonStyle(.borderedProminent).tint(.blue).controlSize(.small)
                            } else if app.hasUpdate {
                                Button(app.updateMethod == .appStore ? "App Store" : "Get Update") { viewModel.openUpdate(for: app) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            
                            Button(action: { viewModel.hideApp(app) }) {
                                Image(systemName: "eye.slash").font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("Hide this app")
                        }
                        .frame(width: 150, alignment: .center)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(index % 2 == 1
                        ? Color(nsColor: .controlBackgroundColor).opacity(0.3)
                        : Color.clear)
                    
                    Divider()
                }
                }
                }
            }
        }
    }
    
    var hiddenListView: some View {
        VStack(spacing: 0) {
            // Sticky header row
            HStack(spacing: 12) {
                Text("Application")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Installed Version")
                    .frame(width: 130, alignment: .center)
                Text("Action")
                    .frame(width: 80, alignment: .center)
            }

            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            ScrollView {
                if viewModel.filteredHiddenApps.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        if !viewModel.searchText.isEmpty || viewModel.hiddenFilterMode != .all {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("No Matching Hidden Apps")
                                .font(.title2)
                            Text("No hidden apps match your current search or filter.")
                                .foregroundColor(.secondary)
                            Button("Clear Search") { viewModel.searchText = ""; viewModel.hiddenFilterMode = .all }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("No Hidden Apps")
                                .font(.title2)
                            Text("Use the eye icon on any app to hide it.")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.filteredHiddenApps.enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 12) {
                                // Icon + name + badge
                                HStack(spacing: 8) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 28, height: 28)
                                    } else {
                                        Image(systemName: "app.fill")
                                            .resizable()
                                            .frame(width: 28, height: 28)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(app.name)
                                                .font(.system(size: 13, weight: .medium))
                                            
                                            if app.isEdgeApp {
                                                Text("Edge App")
                                                    .font(.system(size: 8, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue)
                                                    .cornerRadius(3)
                                            } else if app.isSystemOSUpdate {
                                                Text("macOS Update")
                                                    .font(.system(size: 8, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Color.gray)
                                                    .cornerRadius(3)
                                            } else {
                                                Text("Hidden")
                                                    .font(.system(size: 8, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange)
                                                    .cornerRadius(3)
                                            }
                                        }
                                        if let bid = app.bundleIdentifier {
                                            Text(bid)
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // Installed version
                                Text(app.currentVersion)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 130, alignment: .center)
                                
                                // Action
                                Group {
                                    if !app.isSystemOSUpdate && !app.isEdgeApp {
                                        Button(action: { viewModel.unhideApp(app) }) {
                                            Label("Show", systemImage: "eye")
                                        }
                                        .controlSize(.small)
                                    } else {
                                        Text("")
                                    }
                                }
                                .frame(width: 80, alignment: .center)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(index % 2 == 1
                                ? Color(nsColor: .controlBackgroundColor).opacity(0.3)
                                : Color.clear)
                            
                            Divider()
                        }
                    }
                }
            }
        }
    }

    var brewListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Homebrew Package")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Installed Version")
                    .frame(width: 130, alignment: .center)
                Text("Latest Version")
                    .frame(width: 130, alignment: .center)
                Text("Status")
                    .frame(width: 110, alignment: .center)
                Text("Action")
                    .frame(width: 100, alignment: .center)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if viewModel.isScanningBrew {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Checking Homebrew casks...")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredBrewUpdates.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Homebrew Casks Found")
                        .font(.title2)
                    Text("No installed Homebrew casks were reported by Homebrew.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.filteredBrewUpdates.enumerated()), id: \.element.id) { index, cask in
                            HStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "shippingbox.fill")
                                        .frame(width: 28, height: 28)
                                        .foregroundColor(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cask.token)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(cask.kind.rawValue)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        if let error = cask.updateError {
                                            Text(error)
                                                .font(.system(size: 10))
                                                .foregroundColor(.red)
                                                .lineLimit(1)
                                                .help(error)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(cask.installedVersion)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 130, alignment: .center)

                                Text(cask.latestVersion)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(
                                        cask.needsRepair ? .red : (cask.hasUpdate ? .orange : .green)
                                    )
                                    .fontWeight(.bold)
                                    .frame(width: 130, alignment: .center)

                                Group {
                                    if cask.isPinned {
                                        Label("Pinned", systemImage: "pin.fill")
                                            .foregroundColor(.secondary)
                                    } else if cask.isUpdating {
                                        HStack(spacing: 4) {
                                            ProgressView().scaleEffect(0.6)
                                            Text("Updating")
                                        }
                                        .foregroundColor(.blue)
                                    } else if cask.needsRepair {
                                        Label("Repair Needed", systemImage: "wrench.and.screwdriver.fill")
                                            .foregroundColor(.red)
                                    } else if cask.hasUpdate {
                                        Label("Update Ready", systemImage: "arrow.up.circle.fill")
                                            .foregroundColor(.orange)
                                    } else {
                                        Label("Up to Date", systemImage: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .font(.system(size: 11))
                                .frame(width: 110, alignment: .center)

                                Group {
                                    if cask.canUpdate {
                                        Button(cask.needsRepair ? "Reinstall" : "Update") {
                                            viewModel.updateBrewCask(cask)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(cask.isUpdating || viewModel.isUpdatingAllBrew)
                                    } else {
                                        Text("—")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(width: 100, alignment: .center)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(index % 2 == 1
                                ? Color(nsColor: .controlBackgroundColor).opacity(0.3)
                                : Color.clear)

                            Divider()
                        }
                    }
                }
            }
        }
    }
    
    var tempFilesListView: some View {
        VStack(spacing: 0) {
            // Sticky header
            HStack(spacing: 12) {
                Text("File / Folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Application")
                    .frame(width: 150, alignment: .leading)
                Text("Category")
                    .frame(width: 100, alignment: .center)
                Text("Size")
                    .frame(width: 90, alignment: .trailing)
                Text("Action")
                    .frame(width: 80, alignment: .center)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            if viewModel.isScanningTempFiles {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView().scaleEffect(1.5)
                    Text("Scanning temporary files...")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if viewModel.tempFiles.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "trash.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Temporary Files Scanned")
                        .font(.title2)
                    Text("Click \"Scan\" to find cache and temporary files.")
                        .foregroundColor(.secondary)
                    Button("Scan Temporary Files") { viewModel.scanTempFiles() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Total size banner
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("Total reclaimable space: **\(viewModel.totalTempFileSize)**")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))
                
                Divider()
                
                if viewModel.filteredTempFiles.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Matching Files")
                            .font(.title2)
                        Text("No temporary files match your current search or filter.")
                            .foregroundColor(.secondary)
                        Button("Clear Search") { viewModel.searchText = ""; viewModel.tempFileFilterMode = nil }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.filteredTempFiles.enumerated()), id: \.element.id) { index, file in
                            HStack(spacing: 12) {
                                // Icon + file name
                                HStack(spacing: 8) {
                                    Image(systemName: iconForCategory(file.category))
                                        .foregroundColor(colorForCategory(file.category))
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(file.fileName)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1)
                                            if file.isCritical {
                                                Text("System")
                                                    .font(.system(size: 8, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.red.opacity(0.7))
                                                    .cornerRadius(3)
                                            }
                                        }
                                        Text(file.path)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // App name
                                Text(file.appName)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .frame(width: 150, alignment: .leading)
                                
                                // Category badge
                                Text(file.category.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(colorForCategory(file.category))
                                    .cornerRadius(4)
                                    .frame(width: 100, alignment: .center)
                                
                                // Size
                                Text(file.formattedSize)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 90, alignment: .trailing)
                                
                                // Delete button
                                Group {
                                    if file.isCritical {
                                        Image(systemName: "lock.fill")
                                            .foregroundColor(.secondary)
                                            .help("System-critical file — cannot be deleted")
                                    } else if file.isDeleting {
                                        ProgressView().scaleEffect(0.6)
                                    } else {
                                        Button(action: { viewModel.deleteTempFile(file) }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Delete this item")
                                    }
                                }
                                .frame(width: 80, alignment: .center)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(index % 2 == 1
                                ? Color(nsColor: .controlBackgroundColor).opacity(0.3)
                                : Color.clear)
                            
                            Divider()
                        }
                    }
                }
                }
            }
        }
    }
    
    private func iconForCategory(_ category: TempFileCategory) -> String {
        switch category {
        case .cache: return "archivebox.fill"
        case .logs: return "doc.text.fill"
        case .crashReports: return "exclamationmark.triangle.fill"
        case .tempFiles: return "clock.fill"
        }
    }
    
    private func colorForCategory(_ category: TempFileCategory) -> Color {
        switch category {
        case .cache: return .blue
        case .logs: return .orange
        case .crashReports: return .red
        case .tempFiles: return .purple
        }
    }
    
    var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "app.dashed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Applications Found")
                .font(.title2)
            Text("Click \"Check Updates\" to scan for installed applications.")
                .foregroundColor(.secondary)
            Button("Check Updates") { viewModel.checkForUpdates() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
    
    var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.5)
            Text("Scanning applications...")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
    
    var statusBarView: some View {
        HStack {
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if let scanTime = viewModel.lastScanTime {
                Text("Last scan: \(scanTime, format: .dateTime.month(.abbreviated).day().hour().minute())")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if viewModel.selectedTab == .apps {
                if viewModel.filterMode == .brew {
                    let actionCount = viewModel.filteredBrewUpdates.filter(\.canUpdate).count
                    Text("\(viewModel.filteredBrewUpdates.count) installed • \(actionCount) action(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(viewModel.filteredApps.count) of \(viewModel.apps.count) apps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if viewModel.selectedTab == .hidden {
                Text("\(viewModel.filteredHiddenApps.count) of \(viewModel.hiddenApps.count) hidden app(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("\(viewModel.filteredTempFiles.count) items • \(viewModel.filteredTempFileSize)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
