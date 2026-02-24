import SwiftUI
import UniformTypeIdentifiers


struct ContentView: View {
  @StateObject private var vm = AppViewModel()

  @State private var showDeleteConfirm = false
  @State private var showSettings = false

  var body: some View {
    NavigationSplitView {
      List(selection: selectionBinding) {
        Section("Scope") {
          Text("All VMs").tag(AppViewModel.Selection.all)
        }
        Section("VMs") {
          ForEach(vm.vms, id: \.self) { m in
            Text(m.name).tag(AppViewModel.Selection.vm(m))
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
          Button {
            showSettings = true
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
        }
      }
    } detail: {
      VStack(alignment: .leading, spacing: 12) {
        header
        actions
        snapshotList
        logPanel
      }
      .padding(12)
      .onAppear {
        vm.bootstrap()
        vm.refresh()
      }
    }
    .frame(minWidth: 900, minHeight: 600)
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
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text(vm.selection.label)
          .font(.title2)
          .bold()

        Text(vm.searchDirectoriesSummary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if vm.isBusy {
        ProgressView()
          .controlSize(.small)
      }
    }
  }

  private var actions: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Text("Create tag")
            .frame(width: 90, alignment: .leading)

          TextField("yyyy-MM-dd_HHmmss", text: $vm.createTag)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)

          Button {
            vm.createSnapshots()
          } label: {
            Label("Create", systemImage: "plus.circle")
          }
          .disabled(vm.isBusy)

          Spacer()
        }

        Divider()

        HStack(spacing: 10) {
          Text("Delete tag")
            .frame(width: 90, alignment: .leading)

          Picker("", selection: $vm.selectedTagForDelete) {
            ForEach(vm.snapshotTags, id: \.tag) { st in
              Text(st.tag).tag(st.tag)
            }
          }
          .frame(maxWidth: 260)

          Button(role: .destructive) {
            showDeleteConfirm = true
          } label: {
            Label("Delete", systemImage: "trash")
          }
          .disabled(vm.isBusy || vm.selectedTagForDelete.isEmpty)
          .alert("Delete snapshot?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
              let tag = vm.selectedTagForDelete
              if !tag.isEmpty {
                vm.deleteSnapshots(tag: tag)
              }
            }
          } message: {
            Text("This will delete the snapshot tag '\(vm.selectedTagForDelete)' on every qcow2 disk in the selected scope. This cannot be undone.")
          }

          Spacer()
        }

        if let err = vm.errorText {
          Divider()
          Text(err)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .padding(4)
    } label: {
      Text("Actions")
    }
  }

  private var snapshotList: some View {
    GroupBox {
      if vm.snapshotTags.isEmpty {
        Text("No snapshots found (or no qcow2 disks discovered).")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Table(vm.snapshotTags) {
          TableColumn("Tag") { st in
            Text(st.tag)
          }
          TableColumn("Consistency") { st in
            switch st.consistency {
            case .consistent:
              Text("OK")
            case .partial:
              Text("PARTIAL")
                .foregroundStyle(.orange)
            }
          }
          TableColumn("Disks") { st in
            Text("\(st.presentOnDiskCount)/\(st.totalDiskCount)")
          }
        }
      }
    } label: {
      Text("Snapshots")
    }
  }

  private var logPanel: some View {
    GroupBox {
      TextEditor(text: $vm.logText)
        .font(.system(.caption, design: .monospaced))
        .frame(minHeight: 160)
    } label: {
      Text("Log")
    }
  }
}

private struct SearchDirectoriesSettingsView: View {
  @ObservedObject var vm: AppViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var isFolderImporterPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("VM Search Directories")
        .font(.title3)
        .bold()

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
          isFolderImporterPresented = true
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

        Button("Done") {
          dismiss()
        }
      }
    }
    .padding(16)
    .frame(minWidth: 680, minHeight: 360)
    .fileImporter(
      isPresented: $isFolderImporterPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result else { return }
      for url in urls {
        vm.addSearchDirectory(url)
      }
      vm.refresh()
    }
  }
}
