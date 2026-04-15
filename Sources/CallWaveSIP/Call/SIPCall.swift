import Foundation

/// Represents a SIP call session.
public struct SIPCall: Identifiable, Sendable {
    public typealias ID = UUID

    /// Unique identifier for this call.
    public let id: ID
    /// Call direction.
    public let direction: Direction
    /// Remote party SIP URI.
    public let remoteURI: String
    /// Remote party display name.
    public let remoteDisplayName: String
    /// Time the call was created.
    public let startTime: Date
    /// Current call state.
    public internal(set) var state: SIPCallState

    /// Internal PJSIP call ID. Not exposed to public API consumers.
    let pjCallID: Int32

    public init(
        id: ID = UUID(),
        direction: Direction,
        remoteURI: String,
        remoteDisplayName: String = "",
        startTime: Date = Date(),
        state: SIPCallState = .idle,
        pjCallID: Int32 = -1
    ) {
        self.id = id
        self.direction = direction
        self.remoteURI = remoteURI
        self.remoteDisplayName = remoteDisplayName
        self.startTime = startTime
        self.state = state
        self.pjCallID = pjCallID
    }

    /// Call direction (incoming or outgoing).
    public enum Direction: String, Sendable {
        case incoming
        case outgoing
    }
}

extension SIPCall: Equatable {
    public static func == (lhs: SIPCall, rhs: SIPCall) -> Bool {
        lhs.id == rhs.id
    }
}

extension SIPCall: CustomStringConvertible {
    public var description: String {
        let name = remoteDisplayName.isEmpty ? remoteURI : remoteDisplayName
        return "SIPCall(\(direction.rawValue): \(name), state: \(state))"
    }
}
