import Foundation

/// A DisplayBridge source found on the local network.
public struct DiscoveredSource: Sendable, Hashable, Identifiable {
    public let name: String
    public let host: String
    public let port: UInt16
    public var id: String { "\(host):\(port)" }
}

/// Finds sources advertising themselves over Bonjour and resolves each to the host and
/// port the core can dial. Create and use it on the main thread; `onChange` is called
/// there too.
// NetService is deprecated in favour of Network.framework, but NWBrowser cannot resolve a
// service to a host and port without opening a connection to it, and a connection to a
// source is a client session there.
public final class SourceBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    /// Bonjour service type every source advertises.
    public static let serviceType = "_displaybridge._tcp"

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let onChange: ([DiscoveredSource]) -> Void

    public init(onChange: @escaping ([DiscoveredSource]) -> Void) {
        self.onChange = onChange
        super.init()
        browser.delegate = self
    }

    public func start() {
        browser.searchForServices(ofType: Self.serviceType + ".", inDomain: "local.")
    }

    public func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
    }

    private func publish() {
        onChange(services.compactMap { service in
            guard let host = service.hostName, service.port > 0 else { return nil }
            // "name.local." -> "name.local": the trailing dot confuses some resolvers.
            let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
            return DiscoveredSource(name: service.name, host: trimmed, port: UInt16(service.port))
        })
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        publish()
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        publish()
    }
}
