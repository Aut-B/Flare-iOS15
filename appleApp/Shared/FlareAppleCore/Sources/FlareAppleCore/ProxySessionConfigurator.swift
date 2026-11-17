import Foundation
import KotlinSharedUI
import Network

public final class ProxySessionConfigurator: NSObject, AppleProxySessionConfigurator, @unchecked Sendable {
    public static func install() {
        AppleProxyTransport.shared.configurator = ProxySessionConfigurator()
    }

    public nonisolated func configure(configuration: URLSessionConfiguration, connection: ProxyConnection) {
        configuration.urlCredentialStorage = nil
        if connection.mode == .direct {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
                "ExceptionsList": ["*"], "ExcludeSimpleHostnames": 1,
            ]
            return
        }
        if connection.mode == .system { return }
        // `proxyConfigurations` 是 iOS 17 起才有的 API。deploymentTarget 是 15.0，
        // 不守卫会直接编译失败（"'ProxyConfiguration' is only available in iOS 17.0
        // or newer"）。iOS 15/16 退回 URLSession 一直支持的 connectionProxyDictionary。
        if #available(iOS 17.0, *) {
            configuration.proxyConfigurations = [Self.proxyConfiguration(connection)]
        } else {
            Self.applyLegacyProxy(configuration, connection: connection)
        }
    }

    /// iOS 15/16 的代理回退。
    ///
    /// `URLSessionConfiguration.connectionProxyDictionary` 从 iOS 7 就有，
    /// 支持 HTTPS 与 SOCKS 两类代理，字段名是固定字符串键。
    nonisolated static func applyLegacyProxy(_ configuration: URLSessionConfiguration, connection: ProxyConnection) {
        guard connection.mode == .proxy,
              let host = connection.host, let port = connection.port,
              (1...65535).contains(port.intValue) else { return }
        let value = port.intValue
        switch connection.protocol {
        case .https:
            configuration.connectionProxyDictionary = [
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": value,
            ]
        case .socks5:
            configuration.connectionProxyDictionary = [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": value,
            ]
        default:
            break
        }
    }

    @available(iOS 17.0, *)
    nonisolated static func proxyConfiguration(_ connection: ProxyConnection) -> Network.ProxyConfiguration {
        guard connection.mode == .proxy,
              let host = connection.host, let port = connection.port,
              (1...65535).contains(port.intValue),
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port.intValue)) else {
            preconditionFailure("Invalid resolved proxy configuration")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        var proxy: Network.ProxyConfiguration
        switch connection.protocol {
        case .https:
            proxy = Network.ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        case .socks5:
            proxy = Network.ProxyConfiguration(socksv5Proxy: endpoint)
        default:
            preconditionFailure("Unsupported proxy protocol")
        }
        proxy.allowFailover = false
        return proxy
    }
}
