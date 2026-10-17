import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S06 New Project (docs/navigation-screens.md, docs/api-contract.md W02
/// steps 4–5): validated folder name, exact destination/config preview,
/// and creation as a folder plus empty `opencode.jsonc` — never advertised
/// as repository cloning, Git init, or a commit. The server verifies the
/// actual resolved target; a detected race is explained, not papered over.
struct NewProjectView: View {
    let host: OpenCodeDomain.Host
    let credential: BasicCredential?
    /// Absolute existing parent directory (the resolved location).
    let parentDirectory: String
    var onCreated: (ResolvedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var service = ProjectService(makeTransport: { URLSessionTransport(baseURL: $0) })
    @State private var name = ""
    @State private var phase: Phase = .editing
    @State private var failure: String?

    private enum Phase {
        case editing
        case working
    }

    private var validationError: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil } // empty is the initial state, not an error
        do {
            _ = try FolderName.validate(trimmed)
            return nil
        } catch {
            switch error {
            case FolderName.ValidationError.reserved:
                return "“.” and “..” cannot be used as folder names."
            case FolderName.ValidationError.containsSeparator:
                return "Folder names cannot contain “/” or “\\”."
            default:
                return "Folder names cannot be empty or contain control characters."
            }
        }
    }

    private var targetPath: String {
        let root = parentDirectory.hasSuffix("/") ? String(parentDirectory.dropLast()) : parentDirectory
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? root + "/" : root + "/" + trimmed
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validationError == nil && phase == .editing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    LabeledContent("Parent") {
                        Text(parentDirectory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Folder name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(phase == .working)
                } header: {
                    Text("New Project")
                } footer: {
                    if let validationError {
                        Text(validationError)
                            .foregroundStyle(.red)
                    } else {
                        Text("Creates a folder with an empty opencode.jsonc. It does not clone a repository or run Git.")
                    }
                }
                Section("Preview") {
                    LabeledContent("Folder") {
                        Text(targetPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Config") {
                        Text(targetPath + "/opencode.jsonc")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let failure {
                    Section {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(phase == .working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if phase == .working {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }

    private func create() async {
        phase = .working
        failure = nil
        defer { phase = .editing }
        do {
            let resolved = try await service.createProject(
                at: host.address,
                credential: credential,
                parentDirectory: parentDirectory,
                name: name
            )
            onCreated(resolved)
            dismiss()
        } catch let error as FolderName.ValidationError {
            failure = Self.message(for: error)
        } catch {
            failure = Self.message(for: error)
        }
    }

    private static func message(for error: FolderName.ValidationError) -> String {
        switch error {
        case .empty: return "Enter a folder name."
        case .reserved: return "“.” and “..” cannot be used as folder names."
        case .containsSeparator: return "Folder names cannot contain “/” or “\\”."
        case .containsControlCharacter: return "Folder names cannot contain control characters."
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not create the project (HTTP \(status)). If the folder already exists, open it instead of overwriting it."
        case TransportError.connectionFailed:
            return "The host is unreachable. Nothing was created; try again when it is back."
        default:
            return "The project could not be created. If the folder was created but the config failed, browse to it with Open Folder."
        }
    }
}
