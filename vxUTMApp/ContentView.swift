import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @StateObject private var vm: AppViewModel

  @State private var showDeleteConfirm = false
  @State private var showSettings = false
  @State private var showErrorDetails = false
  @State private var showLogViewer = false
  @State private var showShutdownAllConfirm = false
  @State private var pendingShutdownAllMethod: UTMCtlStopMethod = .request

  @MainActor init(vm: AppViewModel) {
    _vm = StateObject(wrappedValue: vm)
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selectionBinding) {
        Section("Scope") {
          Text("All VMs").tag(AppViewModel.Selection.all)
        }
        Section("VMs") {
          ForEach(vm.vms, id: \.self) { currentVM in
            Text(currentVM.name).tag(AppViewModel.Selection.vm(currentVM))
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 240, ideal: 280)
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Button {
            vm.refresh()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .disabled(vm.isBusy)
        }
        ToolbarItem(placement: .automatic) {
          if vm.errorText != nil {
            Button {
              showErrorDetails = true
            } label: {
              Label("Issue", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
            .help("Show latest error")
            .popover(isPresented: $showErrorDetails, arrowEdge: .top) {
              VStack(alignment: .leading, spacing: 10) {
                Text("Latest Error")
                  .font(.headline)

                ScrollView {
                  Text(vm.errorText ?? "")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140, maxHeight: 260)

                HStack {
                  Spacer()
                  Button("Clear") {
                    vm.errorText = nil
                    showErrorDetails = false
                  }
                }
              }
              .padding(12)
              .frame(width: 460)
            }
          }
        }
        ToolbarItem(placement: .automatic) {
          Button {
            showLogViewer = true
          } label: {
            Label("Log", systemImage: "text.alignleft")
          }
          .help("Show activity log")
          .popover(isPresented: $showLogViewer, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
              Text("Activity Log")
                .font(.headline)

              if vm.logText.isEmpty {
                Text("No log entries yet.")
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              } else {
                ScrollView {
                  Text(vm.logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180, maxHeight: 320)
              }

              HStack {
                Button("Clear") {
                  vm.logText = ""
                }
                .disabled(vm.logText.isEmpty)
                Spacer()
              }
            }
            .padding(12)
            .frame(width: 500)
          }
        }
        ToolbarItem(placement: .automatic) {
          Button {
            showSettings = true
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
        }
      }
    } detail: {
      VStack(alignment: .leading, spacing: 10) {
        header
        backupProgressPanel

        VSplitView {
          vmRuntimePanel
          snapshotsPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      }
      .padding()
      .onAppear {
        vm.bootstrap()
        vm.refresh()
      }
    }
    .frame(minWidth: 960, minHeight: 620)
    .sheet(isPresented: $showSettings) {
      SearchDirectoriesSettingsView(vm: vm)
    }
  }

  private var selectionBinding: Binding<AppViewModel.Selection?> {
    Binding<AppViewModel.Selection?>(
      get: { vm.selection },
      set: { newValue in
        vm.selection = newValue ?? .all
        vm.refresh()
      }
    )
  }

  private var header: some View {
    HStack(alignment: .center) {
      Text(vm.selection.label)
        .font(.title2)
        .bold()

      Spacer()

      HStack(spacing: 8) {
        if case .all = vm.selection {
          Button {
            vm.startAllInScope()
          } label: {
            Label("Start All", systemImage: "play.fill")
          }
          .disabled(vm.isBusy || !vm.hasControllableScopedVMs)

          Menu {
            Button("Graceful Shutdown") {
              pendingShutdownAllMethod = .request
              showShutdownAllConfirm = true
            }
            Button("Force Stop") {
              pendingShutdownAllMethod = .force
              showShutdownAllConfirm = true
            }
            Button("Kill", role: .destructive) {
              pendingShutdownAllMethod = .kill
              showShutdownAllConfirm = true
            }
          } label: {
            Label("Shutdown All", systemImage: "power")
          }
          .disabled(vm.isBusy || !vm.hasControllableScopedVMs)
          .alert("Shutdown all VMs?", isPresented: $showShutdownAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
              vm.shutdownAllInScope(method: pendingShutdownAllMethod)
            }
          } message: {
            Text("Applies '\(pendingShutdownAllMethod.label)' to all controllable VMs in current scope.")
          }
        }

        Button {
          vm.backupScope()
        } label: {
          Label("Backup Scope", systemImage: "archivebox")
        }
        .disabled(!vm.canRunBackup)
        .help(vm.backupBlockedReason ?? "Create one ZIP backup per VM in current scope.")
      }

      if vm.isBusy {
        ProgressView()
          .controlSize(.small)
      }
    }
  }

  private var backupProgressPanel: some View {
    Group {
      if vm.hasBackupJobs || vm.isBackingUp {
        GroupBox("Backups") {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(vm.backupProgressSummary)
                .font(.subheadline)
              if vm.canAbortBackup {
                Button(role: .destructive) {
                  vm.abortBackup()
                } label: {
                  Label("Abort Backup", systemImage: "xmark.circle")
                }
                .controlSize(.small)
              }
              Spacer()
            }

            if let progress = vm.backupOverallProgress {
              ProgressView(value: progress)
            } else if vm.isBackingUp {
              ProgressView()
            }

            ForEach(vm.backupJobs.prefix(6), id: \.id) { job in
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                  Text(job.vmName)
                    .frame(width: 220, alignment: .leading)
                  Text(job.state.displayLabel)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? .red : .secondary)
                  Text(job.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                  Spacer()
                }
                ProgressView(value: job.progress)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private var vmRuntimePanel: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        if vm.scopedVMs.isEmpty {
          Text("No VMs discovered.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Table(vm.scopedVMs) {
            TableColumn("VM") { currentVM in
              VStack(alignment: .leading, spacing: 2) {
                Text(currentVM.name)
                if let detail = vm.runtimeInfo(for: currentVM).detail {
                  Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }

            TableColumn("Status") { currentVM in
              RuntimeBadge(status: vm.runtimeInfo(for: currentVM).status)
            }

            TableColumn("Actions") { currentVM in
              HStack(spacing: 6) {
                Button {
                  vm.start(vm: currentVM)
                } label: {
                  Image(systemName: "play.fill")
                }
                .help("Start")
                .disabled(vm.isBusy || vm.runtimeInfo(for: currentVM).controlIdentifier == nil)

                Button {
                  vm.suspend(vm: currentVM)
                } label: {
                  Image(systemName: "pause.fill")
                }
                .help("Suspend")
                .disabled(vm.isBusy || vm.runtimeInfo(for: currentVM).controlIdentifier == nil)

                Menu {
                  Button("Graceful Shutdown") { vm.stop(vm: currentVM, method: .request) }
                  Button("Force Stop") { vm.stop(vm: currentVM, method: .force) }
                  Button("Kill", role: .destructive) { vm.stop(vm: currentVM, method: .kill) }
                } label: {
                  Image(systemName: "power")
                }
                .help("Stop options")
                .disabled(vm.isBusy || vm.runtimeInfo(for: currentVM).controlIdentifier == nil)
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } label: {
      Text("VM Runtime")
    }
    .frame(minHeight: 220, maxHeight: .infinity)
  }

  private var snapshotsPanel: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          TextField("Snapshot tag (yyyy-MM-dd_HHmmss)", text: $vm.createTag)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 300)

          Button {
            vm.createSnapshots()
          } label: {
            Label("Create", systemImage: "plus.circle")
          }
          .disabled(vm.isBusy || !vm.canMutateSnapshots)

          Divider()
            .frame(height: 18)

          Picker("Tag", selection: $vm.selectedTagForDelete) {
            ForEach(vm.snapshotTags, id: \.tag) { st in
              Text(st.tag).tag(st.tag)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 300)

          Button(role: .destructive) {
            showDeleteConfirm = true
          } label: {
            Label("Delete", systemImage: "trash")
          }
          .disabled(vm.isBusy || vm.selectedTagForDelete.isEmpty || !vm.canMutateSnapshots)
          .alert("Delete snapshot?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
              let tag = vm.selectedTagForDelete
              if !tag.isEmpty {
                vm.deleteSnapshots(tag: tag)
              }
            }
          } message: {
            Text("Delete '\(vm.selectedTagForDelete)' for all qcow2 disks in this scope.")
          }

          Spacer()
        }

        if let blockedReason = vm.snapshotMutationBlockedReason {
          Text(blockedReason)
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if vm.snapshotTags.isEmpty {
          Text("No snapshots found.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } else {
          Table(vm.snapshotTags) {
            TableColumn("Tag") { st in
              Text(st.tag)
            }
            TableColumn("State") { st in
              switch st.consistency {
              case .consistent:
                Text("OK")
              case .partial:
                Text("Partial")
                  .foregroundStyle(.orange)
              }
            }
            TableColumn("Disks") { st in
              Text("\(st.presentOnDiskCount)/\(st.totalDiskCount)")
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } label: {
      Text("Snapshots")
    }
    .frame(minHeight: 220, maxHeight: .infinity)
  }

}

private struct RuntimeBadge: View {
  let status: VMRuntimeStatus

  private var tint: Color {
    switch status {
    case .started:
      return .green
    case .starting, .stopping, .resuming, .pausing:
      return .orange
    case .stopped, .paused:
      return .gray
    case .unavailable, .unresolved, .unknown:
      return .red
    }
  }

  var body: some View {
    Text(status.displayLabel)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(tint.opacity(0.16), in: Capsule())
      .foregroundStyle(tint)
  }
}

private struct SearchDirectoriesSettingsView: View {
  private enum ImportTarget {
    case directory
    case utmctl
    case backupDirectory
  }

  @ObservedObject var vm: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var isImporterPresented = false
  @State private var importTarget: ImportTarget = .directory

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Settings")
        .font(.title3)
        .bold()

      GroupBox("UTM Control Binary") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Choose the utmctl binary used for VM start/stop/status actions.")
            .foregroundStyle(.secondary)

          TextField("/Applications/UTM.app/Contents/MacOS/utmctl", text: $vm.utmctlExecutablePath)
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))

          HStack {
            Button {
              vm.applyUTMCtlExecutablePathFromTextField()
            } label: {
              Label("Apply Path", systemImage: "checkmark")
            }

            Button {
              importTarget = .utmctl
              isImporterPresented = true
            } label: {
              Label("Choose Binary", systemImage: "folder")
            }

            Button {
              vm.useDefaultUTMCtlExecutablePath()
            } label: {
              Label("Use UTM.app Default", systemImage: "arrow.uturn.backward")
            }

            Button {
              vm.clearUTMCtlExecutablePathOverride()
            } label: {
              Label("Clear Override", systemImage: "xmark.circle")
            }

            Spacer()
          }
        }
      }

      GroupBox("VM Search Directories") {
        VStack(alignment: .leading, spacing: 8) {
          Text("The app scans these directories for *.utm bundles. Changes persist across restarts.")
            .foregroundStyle(.secondary)

          List {
            ForEach(vm.vmSearchDirectories, id: \.path) { directoryURL in
              Text(directoryURL.path)
                .textSelection(.enabled)
            }
            .onDelete { offsets in
              vm.removeSearchDirectories(at: offsets)
              vm.refresh()
            }
          }
          .frame(minHeight: 220)

          HStack {
            Button {
              importTarget = .directory
              isImporterPresented = true
            } label: {
              Label("Add Directory", systemImage: "plus")
            }

            Button(role: .destructive) {
              vm.clearSearchDirectories()
              vm.refresh()
            } label: {
              Label("Clear All", systemImage: "trash")
            }
            .disabled(vm.vmSearchDirectories.isEmpty)

            Spacer()
          }
        }
      }

      GroupBox("Backup Directory") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Backups create one ZIP archive per VM in scope in this directory.")
            .foregroundStyle(.secondary)

          TextField("/Users/.../Documents/vxUTMBackups", text: $vm.backupDirectoryPath)
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))

          HStack {
            Button {
              vm.applyBackupDirectoryPathFromTextField()
            } label: {
              Label("Apply Path", systemImage: "checkmark")
            }

            Button {
              importTarget = .backupDirectory
              isImporterPresented = true
            } label: {
              Label("Choose Directory", systemImage: "folder")
            }

            Button {
              vm.useDefaultBackupDirectory()
            } label: {
              Label("Use Default", systemImage: "arrow.uturn.backward")
            }

            Spacer()
          }
        }
      }

      HStack {
        Spacer()
        Button("Done") {
          dismiss()
        }
      }
    }
    .padding(16)
    .frame(minWidth: 760, minHeight: 460)
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: importerAllowedContentTypes,
      allowsMultipleSelection: importerAllowsMultipleSelection
    ) { result in
      guard case .success(let urls) = result else { return }
      switch importTarget {
      case .directory:
        for directoryURL in urls {
          vm.addSearchDirectory(directoryURL)
        }
        vm.refresh()
      case .utmctl:
        guard let first = urls.first else { return }
        vm.setUTMCtlExecutableURL(first)
      case .backupDirectory:
        guard let first = urls.first else { return }
        vm.setBackupDirectoryURL(first)
      }
    }
  }

  private var importerAllowedContentTypes: [UTType] {
    switch importTarget {
    case .directory:
      return [.folder]
    case .utmctl:
      return [.unixExecutable, .data]
    case .backupDirectory:
      return [.folder]
    }
  }

  private var importerAllowsMultipleSelection: Bool {
    switch importTarget {
    case .directory:
      return true
    case .utmctl:
      return false
    case .backupDirectory:
      return false
    }
  }
}
