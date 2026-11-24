#if DEBUG
  import SwiftUI
  import UniformTypeIdentifiers

  /// Manual, disposable IC0 Files-provider evidence UI. It is unavailable in Release.
  @MainActor
  struct PodcastFilesDevelopmentProbeView: View {
    static var isRequested: Bool {
      ProcessInfo.processInfo.environment["WHIRR_FILES_DEVELOPMENT_PROBE"] == "1"
    }

    private static let payload = Data("whirr-ic0-synthetic-v1".utf8)
    private static let receiptName = "receipt.json"

    @State private var receipt: Receipt?
    @State private var showingImporter = false
    @State private var status = "No probe has been run."

    var body: some View {
      List {
        Section("Development Files probe") {
          Text(status)
            .foregroundStyle(status.hasPrefix("PASS") ? Color.green : Color.secondary)
          Button("Choose Synology folder / create synthetic file") { showingImporter = true }
          Button("Verify saved probe after relaunch", action: verify)
            .disabled(receipt == nil)
          Button("Replace synthetic generation", action: replace)
            .disabled(receipt == nil)
        }
        Section("Manual evidence") {
          Text(
            "Choose a Synology/File Provider folder, create the synthetic file, then relaunch Whirr and press Verify. Press Replace, then repeat while offline and after revoking access."
          )
          .font(.footnote)
          Text("Local tests do not establish physical File Provider evidence.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("IC0 Files probe")
      .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) {
        result in
        guard case .success(let urls) = result, let url = urls.first else {
          if case .failure = result { status = "FAIL: folder selection cancelled or unavailable." }
          return
        }
        create(in: url)
      }
      .task { loadReceipt() }
    }

    private func create(in folder: URL) {
      let newReceipt = Receipt(identifier: UUID(), bookmark: Data(), expectedPayload: Self.payload)
      Task {
        do {
          let outcome = try PodcastFilesDevelopmentProbe(identifier: newReceipt.identifier)
            .create(in: folder, payload: Self.payload)
          var saved = newReceipt
          saved.bookmark = outcome.bookmark
          try saveReceipt(saved)
          receipt = saved
          status = "PASS: synthetic file created (\(Self.payload.count) bytes)."
        } catch is CancellationError {
          status = "FAIL: operation cancelled."
        } catch {
          status = "FAIL: synthetic file could not be created."
        }
      }
    }

    private func verify() {
      guard let receipt else { return }
      Task {
        do {
          let result = try PodcastFilesDevelopmentProbe(identifier: receipt.identifier)
            .verify(bookmark: receipt.bookmark, expected: receipt.expectedPayload)
          status = result.bookmarkWasStale ? "PASS: verified; bookmark was refreshed." : "PASS: saved probe verified."
          if result.bookmarkWasStale {
            var refreshed = receipt
            refreshed.bookmark = result.bookmark
            try saveReceipt(refreshed)
            self.receipt = refreshed
          }
        } catch is CancellationError {
          status = "FAIL: operation cancelled."
        } catch {
          status = "FAIL: saved probe could not be verified."
        }
      }
    }

    private func replace() {
      guard let receipt else { return }
      Task {
        do {
          let next =
            receipt.expectedPayload == Self.payload
            ? Data("whirr-ic0-synthetic-v2".utf8) : Self.payload
          let outcome = try PodcastFilesDevelopmentProbe(identifier: receipt.identifier)
            .replace(bookmark: receipt.bookmark, expectedPrevious: receipt.expectedPayload, payload: next)
          var updated = receipt
          updated.bookmark = outcome.bookmark
          updated.expectedPayload = next
          try saveReceipt(updated)
          self.receipt = updated
          status = "PASS: synthetic generation replaced (\(next.count) bytes)."
        } catch is CancellationError {
          status = "FAIL: operation cancelled."
        } catch {
          status = "FAIL: synthetic generation could not be replaced."
        }
      }
    }

    private func receiptURL() throws -> URL {
      let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let directory = base.appendingPathComponent("WhirrCloudKitIC0Files", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory.appendingPathComponent(Self.receiptName)
    }

    private func saveReceipt(_ receipt: Receipt) throws {
      let data = try JSONEncoder().encode(receipt)
      try data.write(to: try receiptURL(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func loadReceipt() {
      do {
        receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: try receiptURL()))
        status = "Saved probe receipt loaded."
      } catch { status = "No saved probe receipt found." }
    }

    private struct Receipt: Codable, Sendable {
      let identifier: UUID
      var bookmark: Data
      var expectedPayload: Data
    }
  }
#endif
