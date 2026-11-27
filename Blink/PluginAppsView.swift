import SwiftUI

@MainActor
struct PluginAppsView: View {
  @State private var packages: [PluginPackage] = []
  @State private var review: Review?
  @State private var showingURL = false
  @State private var input = ""
  @State private var downloading = false
  @State private var notice: Notice?

  private static let root = PluginLibrary.root
  private static let installed = PluginLibrary.installed
  private static let bundled = PluginLibrary.bundled

  /// Apps offered by default under Available until they're installed.
  private struct Featured {
    let id, name, summary, repository: String
    /// Why Blink can't run it yet; nil when it can.
    let unavailable: String?
  }

  private static let featured = [
    Featured(id: "org.blink.database", name: "Database Workbench",
             summary: "MySQL and MariaDB client: browse, edit, run SQL, SSH through your hosts.",
             repository: "https://github.com/myneid/wink-database", unavailable: nil),
  ]

  var body: some View {
    List {
      Section {
        Button("Install from GitHub…") {
          input = ""
          showingURL = true
        }
        .disabled(downloading)
        if downloading { ProgressView("Downloading for review…") }
      }
      Section("Apps") {
        ForEach(packages, id: \.manifest.id) { package in
          Button {
            open(package)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(package.manifest.name)
              let commands = PluginCommands.shared.commands(of: package.manifest.id)
              Text(commands.isEmpty ? "Opens in a new tab" : "Opens in a new tab · command: " + commands.joined(separator: ", "))
                .font(.caption).foregroundColor(.secondary)
            }
          }
          .contextMenu {
            Button("Open in New Tab") { open(package) }
            if let source = sourceReceipt(for: package),
               let link = source["repository"], let url = URL(string: link) {
              Link("Open GitHub", destination: url)
              Button("Check for Update") { fetchUpdate(package, receipt: source) }
                .disabled(downloading)
            }
          }
        }
      }
      let available = Self.featured.filter { item in !packages.contains { $0.manifest.id == item.id } }
      if !available.isEmpty {
        Section(header: Text("Available"), footer: Text("Apps are downloaded from GitHub for review before anything is installed.")) {
          ForEach(available, id: \.id) { item in
            Button {
              download(item.repository)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(item.name)
                  Spacer()
                  Text(item.unavailable == nil ? "Install…" : "Wink only").font(.caption).foregroundColor(.secondary)
                }
                Text(item.unavailable ?? item.summary).font(.caption).foregroundColor(.secondary)
              }
            }
            .disabled(downloading || item.unavailable != nil)
          }
        }
      }
    }
    .navigationTitle("Apps")
    .onAppear(perform: reload)
    .alert("Install from GitHub", isPresented: $showingURL) {
      TextField("https://github.com/owner/repo", text: $input)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Download for Review") { download(input) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Download a pinned snapshot of a public repository or app folder. No build scripts are run.")
    }
    .alert(item: $notice) { notice in
      Alert(title: Text(notice.title), message: Text(notice.message))
    }
    .sheet(item: $review) { review in
      NavigationView {
        List {
          Section("App") {
            Text(review.prepared.package.manifest.name)
            Text(review.prepared.package.manifest.id)
            Text("Version: " + review.prepared.package.manifest.version)
            Text("Permissions: " + (review.prepared.package.manifest.permissions.isEmpty ? "None" : review.prepared.package.manifest.permissions.joined(separator: ", ")))
            if let commands = review.prepared.package.manifest.commands, !commands.isEmpty {
              Text("Commands: " + commands.joined(separator: ", "))
            }
          }
          if !review.conflicts.isEmpty {
            Section(header: Text("Can't Install"), footer: Text("Another app or Blink already uses these command names.")) {
              ForEach(review.conflicts, id: \.self) { Text($0).foregroundColor(.red) }
            }
          }
          Section("Source") {
            Text(review.prepared.source.repositoryURL)
            Text(review.prepared.commit).font(.footnote.monospaced())
          }
        }
        .navigationTitle(review.current == nil ? "Review App" : "Review Update")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { self.review = nil }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(review.current == nil ? "Install" : "Update") { install(review) }
              .disabled(!review.conflicts.isEmpty)
          }
        }
      }
      .navigationViewStyle(.stack)
    }
  }

  private func reload() {
    PluginCommands.shared.refresh()
    packages = PluginLibrary.all()
      .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
  }

  /// Full screen in a new Blink tab.
  private func open(_ package: PluginPackage) {
    guard let space = PluginCommands.activeSpace else {
      notice = Notice(title: "Can't Open App", message: "Open a Blink window first.")
      return
    }
    space.openPluginApp(package.manifest.id)
  }

  private func loadPackages(from folder: URL?) -> [PluginPackage] {
    guard let folder, let entries = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries.compactMap { try? PluginPackage(root: $0) }
  }

  private func sourceReceipt(for package: PluginPackage) -> [String: String]? {
    guard let data = try? Data(contentsOf: package.root.appendingPathComponent(".wink-source.json")) else { return nil }
    return try? JSONDecoder().decode([String: String].self, from: data)
  }

  private func fetchUpdate(_ current: PluginPackage, receipt: [String: String]) {
    guard let repository = receipt["repository"], let path = receipt["path"] else { return }
    let ref = receipt["ref"] ?? ""
    let link = ref.isEmpty && path.isEmpty ? repository
      : repository + "/tree/" + (ref.isEmpty ? "HEAD" : ref) + (path.isEmpty ? "" : "/" + path)
    download(link, updating: current, receipt: receipt)
  }

  private func download(_ link: String, updating current: PluginPackage? = nil, receipt: [String: String] = [:]) {
    guard !downloading else { return }
    downloading = true
    Task {
      defer { downloading = false }
      do {
        let source = try GitHubPluginSource(link)
        let prepared = try await PluginInstaller().prepare(source, staging: Self.root.appendingPathComponent("Downloads"))
        if let current {
          guard current.manifest.id == prepared.package.manifest.id else {
            throw PluginPackage.Failure.invalid("The publisher changed the app ID.")
          }
          if receipt["commit"] == prepared.commit {
            notice = Notice(title: "Up to Date", message: current.manifest.name)
            return
          }
        }
        review = Review(prepared: prepared, current: current, receipt: receipt,
                        conflicts: PluginCommands.shared.conflicts(for: prepared.package))
      } catch {
        notice = Notice(title: "Download Failed", message: error.localizedDescription)
      }
    }
  }

  private func install(_ review: Review) {
    self.review = nil
    do {
      if let current = review.current {
        guard sourceReceipt(for: current) == review.receipt else {
          throw PluginPackage.Failure.invalid("The installed app changed. Check for updates again.")
        }
        try review.prepared.update(current, receipt: review.receipt, backups: Self.root.appendingPathComponent("Backups"))
      } else {
        let bundledIDs = Set(loadPackages(from: Self.bundled).map(\.manifest.id))
        _ = try review.prepared.install(in: Self.installed, bundledIDs: bundledIDs)
      }
      reload()
    } catch {
      notice = Notice(title: "Could Not Install App", message: error.localizedDescription)
    }
  }

  private struct Review: Identifiable {
    let id = UUID()
    let prepared: PreparedPlugin
    let current: PluginPackage?
    let receipt: [String: String]
    let conflicts: [String]
  }

  private struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
  }
}
