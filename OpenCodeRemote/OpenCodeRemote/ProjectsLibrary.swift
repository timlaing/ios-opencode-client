import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S04 app state: the per-host project inventory behind the Projects tab
/// (docs/navigation-screens.md S04, docs/api-contract.md W02). Projects are
/// scoped by local host UUID; rows always expose name, path and host so a
/// friendly name is never ambiguous.
@MainActor
@Observable
final class ProjectsLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    private let service: ProjectService
    private var credentialProvider: CredentialProvider?

    private(set) var projectsByHost: [HostID: [Project]] = [:]
    private(set) var errorsByHost: [HostID: String] = [:]
    private(set) var loadingHosts: Set<HostID> = []
    /// Recently opened/created folders, newest first, capped. Local to this
    /// device; W03 drafts bind to these locations.
    private(set) var recentLocations: [(host: OpenCodeDomain.Host, location: ResolvedLocation)] = []

    init(service: ProjectService? = nil, credentialProvider: CredentialProvider? = nil) {
        self.service = service ?? ProjectService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI creates
    /// tab state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] id in hosts?.credential(for: id) }
    }

    func noteRecent(host: OpenCodeDomain.Host, location: ResolvedLocation) {
        recentLocations.removeAll { $0.host.id == host.id && $0.location.directory == location.directory }
        recentLocations.insert((host, location), at: 0)
        if recentLocations.count > 10 {
            recentLocations.removeLast(recentLocations.count - 10)
        }
    }

    /// One host's inventory, or every paired host's. Hosts without a stored
    /// credential are skipped and reported; a host error never blanks the
    /// inventories of other hosts.
    func load(_ entries: [HostLibrary.Entry]) async {
        let targets = entries.filter { !loadingHosts.contains($0.id) }
        for entry in targets {
            loadingHosts.insert(entry.id)
        }
        for entry in targets {
            await load(host: entry.host)
        }
        for entry in targets {
            loadingHosts.remove(entry.id)
        }
    }

    func load(host: OpenCodeDomain.Host) async {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            errorsByHost[host.id] = "Re-pair this host to list its projects."
            return
        }
        do {
            let projects = try await service.projects(at: host.address, credential: credential)
            projectsByHost[host.id] = projects.sorted { lhs, rhs in
                (lhs.name ?? lhs.canonical).localizedCaseInsensitiveCompare(rhs.name ?? rhs.canonical) == .orderedAscending
            }
            errorsByHost[host.id] = nil
        } catch {
            errorsByHost[host.id] = Self.message(for: error)
        }
    }

    /// Projects visible under a host filter, searched by name and path
    /// (case-insensitive). Every row keeps its host for disambiguation.
    func rows(entries: [HostLibrary.Entry], hostFilter: HostID?, search: String) -> [(host: OpenCodeDomain.Host, project: Project)] {
        let visibleHosts = entries.filter { hostFilter == nil || $0.id == hostFilter }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [(host: OpenCodeDomain.Host, project: Project)] = []
        for entry in visibleHosts {
            for project in projectsByHost[entry.id] ?? [] {
                if !needle.isEmpty {
                    let name = project.name ?? ""
                    let matches = name.localizedCaseInsensitiveContains(needle)
                        || project.canonical.localizedCaseInsensitiveContains(needle)
                    guard matches else { continue }
                }
                rows.append((entry.host, project))
            }
        }
        return rows
    }

    func hasLoaded(hostID: HostID) -> Bool {
        projectsByHost[hostID] != nil || errorsByHost[hostID] != nil
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not list projects (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "Projects could not be loaded from this host."
        }
    }
}
