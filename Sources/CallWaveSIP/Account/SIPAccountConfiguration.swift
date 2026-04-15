import Foundation

/// Configuration for a SIP account registration.
public struct SIPAccountConfiguration: Sendable, Equatable {
    /// SIP server domain or IP address.
    public let domain: String
    /// SIP server port.
    public let port: UInt16
    /// SIP authentication username.
    public let username: String
    /// SIP authentication password.
    public let password: String
    /// Display name for the account (optional).
    public let displayName: String?
    /// Authentication realm. Use "*" for any realm.
    public let authRealm: String
    /// Registration timeout in seconds.
    public let registrationTimeout: Int
    /// Keep-alive interval in seconds.
    public let keepAliveInterval: Int
    /// Registration retry interval in seconds.
    public let retryInterval: Int
    /// Random component added to retry interval.
    public let retryRandomInterval: Int
    /// Enable SIP contact rewriting for NAT.
    public let contactRewrite: Bool
    /// Use source port in contact header.
    public let contactUseSourcePort: Bool
    /// SIP transport to use for this account (nil = auto).
    public let transport: AccountTransport?

    public init(
        domain: String,
        port: UInt16 = 5060,
        username: String,
        password: String,
        displayName: String? = nil,
        authRealm: String = "*",
        registrationTimeout: Int = 600,
        keepAliveInterval: Int = 15,
        retryInterval: Int = 5,
        retryRandomInterval: Int = 2,
        contactRewrite: Bool = true,
        contactUseSourcePort: Bool = true,
        transport: AccountTransport? = nil
    ) {
        self.domain = domain
        self.port = port
        self.username = username
        self.password = password
        self.displayName = displayName
        self.authRealm = authRealm
        self.registrationTimeout = registrationTimeout
        self.keepAliveInterval = keepAliveInterval
        self.retryInterval = retryInterval
        self.retryRandomInterval = retryRandomInterval
        self.contactRewrite = contactRewrite
        self.contactUseSourcePort = contactUseSourcePort
        self.transport = transport
    }

    /// Constructs the SIP URI for this account (e.g. "sip:user@domain:port").
    public var sipURI: String {
        let portSuffix = port != 5060 ? ":\(port)" : ""
        if let displayName {
            return "\"\(displayName)\" <sip:\(username)@\(domain)\(portSuffix)>"
        }
        return "sip:\(username)@\(domain)\(portSuffix)"
    }

    /// Constructs the registrar URI (e.g. "sip:domain:port").
    public var registrarURI: String {
        let portSuffix = port != 5060 ? ":\(port)" : ""
        return "sip:\(domain)\(portSuffix)"
    }

    public enum AccountTransport: String, Sendable {
        case udp
        case tcp
        case tls
    }
}
