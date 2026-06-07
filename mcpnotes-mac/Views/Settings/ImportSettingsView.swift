import MCPNotesCore
import SwiftUI

private enum ImportState: Equatable {
    case idle
    case importing(done: Int, total: Int)
    case done(imported: Int, skipped: Int)
    case failed(String)
}

struct ImportSettingsView: View {
    @State private var importState: ImportState = .idle

    private var isImporting: Bool {
        guard case .importing = importState else { return false }
        return true
    }

    var body: some View {
        Form {
            Section("Markdown") {
                Text("Select a folder. All .md files are imported recursively.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Import Markdown Files…") {
                    selectAndImport(recursive: true, extensions: ["md"])
                }
                .disabled(isImporting)
            }
            Section("Apple Notes") {
                Text("Import directly from Apple Notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Import from Apple Notes…") {
                    Task { await performAppleNotesImport() }
                }
                .disabled(isImporting)
            }
            if importState != .idle {
                Section {
                    importStatusRow
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var importStatusRow: some View {
        switch importState {
        case .idle:
            EmptyView()
        case .importing(let done, let total):
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.75)
                if total == 0 {
                    Text("Connecting to Apple Notes…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Importing… \(done) / \(total)")
                        .foregroundStyle(.secondary)
                }
            }
        case .done(let imported, let skipped):
            if skipped == 0 {
                Label(String(localized: "\(imported) notes imported"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(String(localized: "\(imported) imported, \(skipped) skipped"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Markdown folder import

    private func selectAndImport(recursive: Bool, extensions: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Import"
        panel.message = String(localized: "Choose a folder to import notes from")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await performImport(from: url, recursive: recursive, extensions: extensions) }
    }

    private func performImport(from sourceURL: URL, recursive: Bool, extensions: [String]) async {
        let destDir = FileService.notesDirectoryURL
        if sourceURL.resolvingSymlinksInPath() == destDir.resolvingSymlinksInPath() {
            importState = .failed(String(localized: "Cannot import from the current notes folder."))
            return
        }

        let files: [URL]
        do {
            files = try collectFiles(from: sourceURL, recursive: recursive, extensions: extensions)
        } catch {
            importState = .failed(error.localizedDescription)
            return
        }

        importState = .importing(done: 0, total: files.count)
        var imported = 0
        var skipped = 0

        for (i, fileURL) in files.enumerated() {
            if i % 10 == 0 {
                importState = .importing(done: i, total: files.count)
                await Task.yield()
            }
            do {
                try importFile(at: fileURL, to: destDir)
                imported += 1
            } catch {
                skipped += 1
            }
        }

        importState = .done(imported: imported, skipped: skipped)
    }

    private func collectFiles(from root: URL, recursive: Bool, extensions: [String]) throws -> [URL] {
        let fm = FileManager.default
        if recursive {
            var result: [URL] = []
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if extensions.contains(url.pathExtension.lowercased()) {
                    result.append(url)
                }
            }
            return result
        } else {
            return try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { extensions.contains($0.pathExtension.lowercased()) }
        }
    }

    private func importFile(at source: URL, to destDir: URL) throws {
        let raw = try String(contentsOf: source, encoding: .utf8)
        let baseName = sanitizeFilename(source.deletingPathExtension().lastPathComponent)

        let tags: [String]
        let body: String
        if source.pathExtension.lowercased() == "html" {
            tags = []
            body = convertHTMLToMarkdown(raw)
        } else if let parsed = FrontmatterParser.parse(raw) {
            tags = parsed.tags
            body = parsed.body
        } else {
            (tags, body) = extractTagsAndBody(from: raw)
        }

        let destURL = uniqueDestination(name: baseName, in: destDir)
        let content = FrontmatterParser.serialize(uid: UUID(), tags: tags, body: body)
        try content.write(to: destURL, atomically: true, encoding: .utf8)
    }

    private func extractTagsAndBody(from content: String) -> (tags: [String], body: String) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([], content.trimmingCharacters(in: .newlines))
        }
        var closingIndex: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = i
            break
        }
        guard let end = closingIndex else {
            return ([], content.trimmingCharacters(in: .newlines))
        }

        let frontmatterLines = Array(lines[1..<end])
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .init(charactersIn: "\n"))

        var tags: [String] = []
        var inBlockTags = false
        for line in frontmatterLines {
            if line.hasPrefix("tags:") {
                inBlockTags = false
                let value = line.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    inBlockTags = true
                } else if value.hasPrefix("["), value.hasSuffix("]") {
                    tags = String(value.dropFirst().dropLast())
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            } else if inBlockTags {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    let tag = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { tags.append(tag) }
                } else if !trimmed.isEmpty {
                    inBlockTags = false
                }
            }
        }
        return (tags, body)
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed: CharacterSet = .letters.union(.decimalDigits).union(CharacterSet(charactersIn: " -_."))
        var sanitized = String(name.unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        if sanitized.isEmpty { sanitized = "Imported Note" }
        return String(sanitized.prefix(200))
    }

    private func uniqueDestination(name: String, in dir: URL) -> URL {
        var filename = name
        var url = dir.appendingPathComponent("\(filename).md")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            filename = "\(name) \(counter)"
            url = dir.appendingPathComponent("\(filename).md")
            counter += 1
        }
        return url
    }

    // MARK: - Apple Notes direct import

    private func performAppleNotesImport() async {
        importState = .importing(done: 0, total: 0)

        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Notes"
        }
        if !isRunning {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
                NSWorkspace.shared.open(url)
                try? await Task.sleep(for: .seconds(2))
            } else {
                importState = .failed(String(localized: "Apple Notes is not installed."))
                return
            }
        }

        await Task.yield()

        let notes: [AppleNoteData]
        do {
            notes = try fetchAppleNotes()
        } catch {
            importState = .failed(error.localizedDescription)
            return
        }

        guard !notes.isEmpty else {
            importState = .done(imported: 0, skipped: 0)
            return
        }

        importState = .importing(done: 0, total: notes.count)
        let destDir = FileService.notesDirectoryURL
        var imported = 0, skipped = 0

        for (i, note) in notes.enumerated() {
            if i % 10 == 0 { importState = .importing(done: i, total: notes.count); await Task.yield() }
            do { try importAppleNote(note, to: destDir); imported += 1 } catch { skipped += 1 }
        }
        importState = .done(imported: imported, skipped: skipped)
    }

    private func fetchAppleNotes() throws -> [AppleNoteData] {
        let source = """
        tell application id "com.apple.Notes"
            set output to {}
            repeat with aFolder in every folder
                set folderName to name of aFolder
                repeat with aNote in notes of aFolder
                    set end of output to {name of aNote, body of aNote, folderName}
                end repeat
            end repeat
            return output
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw ImportError.scriptFailed("Could not create NSAppleScript")
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let code = info[NSAppleScript.errorNumber] as? Int ?? 0
            let msg  = info[NSAppleScript.errorMessage] as? String ?? "unknown"
            if code == -1743 { throw ImportError.permissionDenied }
            throw ImportError.scriptFailed(msg)
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        var notes: [AppleNoteData] = []
        for i in 1...descriptor.numberOfItems {
            guard let noteDesc = descriptor.atIndex(i) else { continue }
            notes.append(AppleNoteData(
                title:  noteDesc.atIndex(1)?.stringValue ?? "",
                html:   noteDesc.atIndex(2)?.stringValue ?? "",
                folder: noteDesc.atIndex(3)?.stringValue ?? ""
            ))
        }
        return notes
    }

    private func importAppleNote(_ note: AppleNoteData, to destDir: URL) throws {
        let baseName = sanitizeFilename(note.title.isEmpty ? "Imported Note" : note.title)
        let tags: [String] = {
            let f = note.folder.trimmingCharacters(in: .whitespaces)
            guard !f.isEmpty, f.lowercased() != "notes" else { return [] }
            return [f]
        }()
        let body = convertHTMLToMarkdown(note.html)
        let destURL = uniqueDestination(name: baseName, in: destDir)
        let content = FrontmatterParser.serialize(uid: UUID(), tags: tags, body: body)
        try content.write(to: destURL, atomically: true, encoding: .utf8)
    }

    private func convertHTMLToMarkdown(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<head>[\\s\\S]*?</head>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<html[^>]*>|</html>|<body[^>]*>|</body>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(b|strong)[^>]*>", with: "**", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(b|strong)>", with: "**", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(i|em)[^>]*>", with: "*", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(i|em)>", with: "*", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(s|strike|del)[^>]*>", with: "~~", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(s|strike|del)>", with: "~~", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "<a[^>]+href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a>",
            with: "[$2]($1)",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "- ", options: .regularExpression)
        text = text.replacingOccurrences(of: "</li>", with: "\n")
        text = text.replacingOccurrences(of: "</?[uo]l[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br[^>]*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<div[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</div>", with: "\n")
        text = text.replacingOccurrences(of: "<p[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…")
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .newlines)
    }
}

private struct AppleNoteData: Sendable {
    let title: String
    let html: String
    let folder: String
}

private enum ImportError: LocalizedError {
    case scriptFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return msg
        case .permissionDenied: return String(localized: "Access to Apple Notes was denied. Enable it in System Settings → Privacy & Security → Automation.")
        }
    }
}
