import Darwin
import Foundation

/// Discovers whisperASR transcription servers on the local network via Bonjour
/// (`_whisperasr._tcp`, the same service `dns-sd -B _whisperasr._tcp` lists).
/// Uses `NetServiceBrowser`, which resolves each found service straight to a
/// host + port through its delegate, so we can hand the Settings screen a
/// ready-to-use `http://host:port/v1` base URL.
///
/// Created as a SwiftUI `@StateObject`, so its delegate callbacks land on the
/// main run loop and the `@Published` updates are already on the main thread.
final class BonjourBrowser: NSObject, ObservableObject,
                            NetServiceBrowserDelegate, NetServiceDelegate {
    /// A resolved server: its Bonjour instance name and concrete address.
    struct Server: Identifiable, Equatable {
        let name: String
        let host: String
        let port: Int
        var id: String { "\(host):\(port)" }
        /// The OpenAI-compatible base URL clients should configure.
        var baseURL: String { "http://\(host):\(port)/v1" }
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var isSearching = false

    /// Trailing dot + explicit domain is the form `NetServiceBrowser` expects.
    static let serviceType = "_whisperasr._tcp."
    static let domain = "local."

    private let browser = NetServiceBrowser()
    /// Services are retained here while they resolve; dropped once done/failed.
    private var resolving: Set<NetService> = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        servers = []
        resolving.removeAll()
        isSearching = true
        browser.stop()
        browser.searchForServices(ofType: Self.serviceType, inDomain: Self.domain)
    }

    func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        isSearching = false
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self
        resolving.insert(service)          // retain during async resolve
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        isSearching = false
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isSearching = false
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.remove(sender) }
        guard sender.port > 0 else { return }
        // A Mac advertises every interface's address, often including a
        // 169.254.x.x link-local (from an inactive interface) that isn't
        // reachable from the phone. Prefer a routable IPv4; otherwise use the
        // .local name (mDNS picks the right interface); only then a link-local.
        let ipv4s = Self.ipv4Addresses(from: sender)
        if let routable = ipv4s.first(where: Self.isRoutable) {
            add(Server(name: sender.name, host: routable, port: sender.port))
        } else if let hostName = sender.hostName {
            let trimmed = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
            add(Server(name: sender.name, host: trimmed, port: sender.port))
        } else if let any = ipv4s.first {
            add(Server(name: sender.name, host: any, port: sender.port))
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)
    }

    // MARK: - Helpers

    private func add(_ server: Server) {
        guard !servers.contains(where: { $0.id == server.id }) else { return }
        servers.append(server)
    }

    /// Reachable from another device on the LAN — excludes IPv4 link-local
    /// (169.254/16, an unconfigured interface) and loopback (127/8).
    private static func isRoutable(_ ip: String) -> Bool {
        !ip.hasPrefix("169.254.") && !ip.hasPrefix("127.")
    }

    /// Every dotted-quad IPv4 address from a resolved service's `addresses`,
    /// in advertised order.
    private static func ipv4Addresses(from service: NetService) -> [String] {
        var result: [String] = []
        for data in service.addresses ?? [] {
            let host: String? = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress,
                      raw.count >= MemoryLayout<sockaddr>.size,
                      base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                        == sa_family_t(AF_INET) else { return nil }
                var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
            if let host { result.append(host) }
        }
        return result
    }
}
