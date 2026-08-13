// Messages — Codable types for the control socket per docs/protocol.md.
//
// Message kinds:
//   hello    — first line each way at connection start (§3)
//   request  — client → daemon, awaits response (§4.1)
//   response — daemon → client, correlates by id (§4.2)
//   event    — daemon → client, fire-and-forget (§4.3)
//
// We keep the wire types as thin as possible; each request method
// defines its own params/result types in Handlers.swift or nearby.

import Foundation

// MARK: - Version constants (Task 1 landed these in the protocol doc)

enum ProtocolVersion {
    /// Current protocol version. Bump for any breaking wire change.
    static let current: Int = 1
    /// Oldest protocol version the daemon accepts from a client.
    static let minSupported: Int = 1
    /// Daemon build version reported in status + hello.
    static let daemonVersion: String = "0.4.0-alpha"
}

// MARK: - Hello (first message each direction)

/// Client → daemon hello line.
struct ClientHello: Codable {
    let kind: String  // always "hello"
    let protocolVersion: Int
    let client: String
    let clientVersion: String

    enum CodingKeys: String, CodingKey {
        case kind
        case protocolVersion = "protocol_version"
        case client
        case clientVersion = "client_version"
    }
}

/// Daemon → client hello line.
struct DaemonHello: Codable {
    let kind: String  // always "hello"
    let protocolVersion: Int
    let minSupportedVersion: Int
    let daemonVersion: String
    let daemonPid: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case protocolVersion = "protocol_version"
        case minSupportedVersion = "min_supported_version"
        case daemonVersion = "daemon_version"
        case daemonPid = "daemon_pid"
    }

    init() {
        self.kind = "hello"
        self.protocolVersion = ProtocolVersion.current
        self.minSupportedVersion = ProtocolVersion.minSupported
        self.daemonVersion = ProtocolVersion.daemonVersion
        self.daemonPid = Int(ProcessInfo.processInfo.processIdentifier)
    }
}

// MARK: - Request

/// Incoming JSON-RPC request from a client.
struct ControlRequest: Codable {
    let kind: String  // always "request"
    let id: String
    let method: String
    /// Method-specific params. We decode the outer envelope generically
    /// and defer method-specific decoding to the handler.
    let params: AnyCodable
}

// MARK: - Response

/// Response envelope. Exactly one of `result` or `error` is populated.
struct ControlResponse: Codable {
    let kind: String  // always "response"
    let id: String
    let result: AnyCodable?
    let error: ControlError?

    init(id: String, result: AnyCodable) {
        self.kind = "response"
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: String, error: ControlError) {
        self.kind = "response"
        self.id = id
        self.result = nil
        self.error = error
    }
}

struct ControlError: Codable {
    let code: String
    let message: String
    let details: AnyCodable?

    init(code: String, message: String, details: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

// Standard error-code constants per protocol.md §5.
enum ErrorCode {
    static let protocolIncompatible = "protocol_incompatible"
    static let messageTooLarge = "message_too_large"
    static let invalidMessage = "invalid_message"
    static let unknownMethod = "unknown_method"
    static let invalidParams = "invalid_params"
    static let notFound = "not_found"
    static let preconditionFailed = "precondition_failed"
    static let internalError = "internal_error"
}

// MARK: - Event

/// Server-initiated push event. No response.
struct ControlEvent: Codable {
    let kind: String  // always "event"
    let name: String
    let payload: AnyCodable

    init(name: String, payload: AnyCodable) {
        self.kind = "event"
        self.name = name
        self.payload = payload
    }
}

// MARK: - AnyCodable helper

/// Type-erased Codable for method-specific params and results. Lets
/// the envelope stay generic while handlers decode their own concrete
/// types from the wrapped value.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            self.value = arr.map(\.value)
        } else if let obj = try? container.decode([String: AnyCodable].self) {
            self.value = obj.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable: unsupported value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // NSNumber-produced-by-JSONSerialization needs careful handling:
        // NSNumber(int: 0) also satisfies `as? Bool` (returns false), so a
        // naive `case let b as Bool` first-cast would misencode every
        // numeric zero as `false` (and every `1` as `true`). Distinguish
        // real CFBoolean instances via CFGetTypeID before falling through
        // to the numeric cases.
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                try container.encode(n.boolValue)
                return
            }
            let typeStr = String(cString: n.objCType)
            switch typeStr {
            case "f", "d":  // Float, Double
                try container.encode(n.doubleValue)
            default:  // Int-family (c, i, s, l, q, C, I, S, L, Q)
                try container.encode(n.int64Value)
            }
            return
        }
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map(AnyCodable.init))
        case let obj as [String: Any]:
            try container.encode(obj.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: encoder.codingPath,
                                      debugDescription: "AnyCodable: unsupported value")
            )
        }
    }

    /// Attempt to decode the wrapped value into a concrete Codable type.
    /// Handy for handlers turning `AnyCodable` params into their own
    /// typed struct.
    func decodeAs<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }
}
