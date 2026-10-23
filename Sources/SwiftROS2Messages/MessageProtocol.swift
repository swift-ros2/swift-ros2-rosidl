// MessageProtocol.swift
// Core protocols for ROS 2 message types

import Foundation
import SwiftROS2CDR

/// Type information for a ROS 2 message
public struct ROS2MessageTypeInfo: Sendable {
    /// ROS format type name (e.g., "sensor_msgs/msg/Imu")
    public let typeName: String

    /// Type hash for Jazzy+ (e.g., "RIHS01_..."), nil for Humble
    public let typeHash: String?

    public init(typeName: String, typeHash: String? = nil) {
        self.typeName = typeName
        self.typeHash = typeHash
    }

    /// The same type name with no type hash, as the type is advertised on a distribution
    /// without RIHS01 hashes (Humble).
    public var withoutTypeHashes: ROS2MessageTypeInfo {
        ROS2MessageTypeInfo(typeName: typeName, typeHash: nil)
    }
}

/// Type information for a ROS 2 service
public struct ROS2ServiceTypeInfo: Sendable {
    /// ROS format service name (e.g., "example_interfaces/srv/AddTwoInts")
    public let serviceName: String

    /// ROS format request type name (e.g., "example_interfaces/srv/AddTwoInts_Request")
    public let requestTypeName: String

    /// ROS format response type name (e.g., "example_interfaces/srv/AddTwoInts_Response")
    public let responseTypeName: String

    /// Type hash for Jazzy+ on the request side (e.g., "RIHS01_..."), nil for Humble
    public let requestTypeHash: String?

    /// Type hash for Jazzy+ on the response side, nil for Humble
    public let responseTypeHash: String?

    /// Type hash for Jazzy+ of the service itself (`<pkg>/srv/<Service>`), nil for Humble or
    /// when unknown.
    ///
    /// rosidl hashes a service from a description with `request_message`, `response_message`
    /// and `event_message` fields. This is the hash rmw_zenoh_cpp puts in a service's key
    /// expression and liveliness token, next to the service type name (for example
    /// `std_srvs::srv::dds_::Trigger_`), rather than the request or response hash.
    public let serviceTypeHash: String?

    /// Creates service type information. A hash left `nil` means the type has no RIHS01 hash
    /// (Humble) or it is unknown.
    public init(
        serviceName: String,
        requestTypeName: String,
        responseTypeName: String,
        requestTypeHash: String? = nil,
        responseTypeHash: String? = nil,
        serviceTypeHash: String? = nil
    ) {
        self.serviceName = serviceName
        self.requestTypeName = requestTypeName
        self.responseTypeName = responseTypeName
        self.requestTypeHash = requestTypeHash
        self.responseTypeHash = responseTypeHash
        self.serviceTypeHash = serviceTypeHash
    }

    /// The same names with every type hash `nil`, as the service is advertised on a
    /// distribution without RIHS01 hashes (Humble).
    public var withoutTypeHashes: ROS2ServiceTypeInfo {
        ROS2ServiceTypeInfo(
            serviceName: serviceName, requestTypeName: requestTypeName, responseTypeName: responseTypeName)
    }
}

/// Type information for a ROS 2 action.
///
/// Carries the action's user-level Goal / Result / Feedback hashes plus the
/// synthesized wrapper hashes that actually travel on the wire
/// (`<Action>_SendGoal_Request`, `<Action>_SendGoal_Response`,
/// `<Action>_GetResult_Request`, `<Action>_GetResult_Response`,
/// `<Action>_FeedbackMessage`), and the hashes of the two services the action
/// declares (`<Action>_SendGoal`, `<Action>_GetResult`). All hashes are optional —
/// `nil` means `TypeHashNotSupported` on Jazzy or absent on Humble.
///
/// rmw_zenoh_cpp keys an action's roles as services and topics of these types:
/// `send_goal` uses `<Action>_SendGoal` with ``sendGoalServiceTypeHash``,
/// `get_result` uses `<Action>_GetResult` with ``getResultServiceTypeHash``,
/// `feedback` uses `<Action>_FeedbackMessage` with ``feedbackMessageTypeHash``.
/// The `cancel_goal` service (`action_msgs/srv/CancelGoal`) and the `status` topic
/// (`action_msgs/msg/GoalStatusArray`) are the same for every action; their hashes
/// come from those types' own `typeInfo`.
public struct ROS2ActionTypeInfo: Sendable {
    /// ROS format action name (e.g., "example_interfaces/action/Fibonacci")
    public let actionName: String

    public let goalTypeHash: String?
    public let resultTypeHash: String?
    public let feedbackTypeHash: String?

    public let sendGoalRequestTypeHash: String?
    public let sendGoalResponseTypeHash: String?
    public let getResultRequestTypeHash: String?
    public let getResultResponseTypeHash: String?
    public let feedbackMessageTypeHash: String?

    /// Hash of the `<Action>_SendGoal` service, the type of the action's `send_goal` service.
    public let sendGoalServiceTypeHash: String?
    /// Hash of the `<Action>_GetResult` service, the type of the action's `get_result` service.
    public let getResultServiceTypeHash: String?

    /// Creates action type information. Pass `nil` for a hash that is unknown, or for every
    /// hash on Humble, which has no RIHS01 hashes. `swift-ros2-gen` fills in all of them.
    public init(
        actionName: String,
        goalTypeHash: String?,
        resultTypeHash: String?,
        feedbackTypeHash: String?,
        sendGoalRequestTypeHash: String?,
        sendGoalResponseTypeHash: String?,
        getResultRequestTypeHash: String?,
        getResultResponseTypeHash: String?,
        feedbackMessageTypeHash: String?,
        sendGoalServiceTypeHash: String? = nil,
        getResultServiceTypeHash: String? = nil
    ) {
        self.actionName = actionName
        self.goalTypeHash = goalTypeHash
        self.resultTypeHash = resultTypeHash
        self.feedbackTypeHash = feedbackTypeHash
        self.sendGoalRequestTypeHash = sendGoalRequestTypeHash
        self.sendGoalResponseTypeHash = sendGoalResponseTypeHash
        self.getResultRequestTypeHash = getResultRequestTypeHash
        self.getResultResponseTypeHash = getResultResponseTypeHash
        self.feedbackMessageTypeHash = feedbackMessageTypeHash
        self.sendGoalServiceTypeHash = sendGoalServiceTypeHash
        self.getResultServiceTypeHash = getResultServiceTypeHash
    }

    /// The same action name with every type hash `nil`, as the action is advertised on a
    /// distribution without RIHS01 hashes (Humble).
    public var withoutTypeHashes: ROS2ActionTypeInfo {
        ROS2ActionTypeInfo(
            actionName: actionName, goalTypeHash: nil, resultTypeHash: nil, feedbackTypeHash: nil,
            sendGoalRequestTypeHash: nil, sendGoalResponseTypeHash: nil, getResultRequestTypeHash: nil,
            getResultResponseTypeHash: nil, feedbackMessageTypeHash: nil)
    }
}

// MARK: - CDR Protocols

/// Protocol for types that can be serialized to CDR format
public protocol CDREncodable {
    func encode(to encoder: CDREncoder) throws
}

/// Protocol for types that can be deserialized from CDR format
public protocol CDRDecodable {
    init(from decoder: CDRDecoder) throws
}

/// Combined CDR encoding and decoding
public typealias CDRCodable = CDREncodable & CDRDecodable

// MARK: - Message Protocols

/// Base protocol for ROS 2 message types
public protocol ROS2MessageType: Sendable {
    /// The type name and the type hash of the default schema (Jazzy and later).
    static var typeInfo: ROS2MessageTypeInfo { get }

    /// The type name and the type hash this type has on the wire for `distro`: `nil` hash where
    /// `distro` has no RIHS01 hashes (Humble). A type whose fields differ among distributions
    /// returns each distribution's hash; every other type has the default implementation.
    static func typeInfo(for distro: ROS2Distro) -> ROS2MessageTypeInfo
}

extension ROS2MessageType {
    /// ``typeInfo``, without its hash where `distro` has no RIHS01 hashes (Humble).
    public static func typeInfo(for distro: ROS2Distro) -> ROS2MessageTypeInfo {
        distro.supportsTypeHash ? typeInfo : typeInfo.withoutTypeHashes
    }
}

/// A message type that supports both publish and subscribe
public typealias ROS2Message = ROS2MessageType & CDRCodable

// MARK: - Service Protocol

/// Protocol for ROS 2 service types
public protocol ROS2ServiceType: Sendable {
    associatedtype Request: CDRCodable & Sendable
    associatedtype Response: CDRCodable & Sendable
    /// The service, request and response names and hashes of the default schema (Jazzy and
    /// later).
    static var typeInfo: ROS2ServiceTypeInfo { get }

    /// The names and hashes this service has on the wire for `distro`: `nil` hashes where
    /// `distro` has no RIHS01 hashes (Humble). A service whose request or response differs among
    /// distributions returns each distribution's hashes; every other service has the default
    /// implementation.
    static func typeInfo(for distro: ROS2Distro) -> ROS2ServiceTypeInfo
}

extension ROS2ServiceType {
    /// ``typeInfo``, without its hashes where `distro` has no RIHS01 hashes (Humble).
    public static func typeInfo(for distro: ROS2Distro) -> ROS2ServiceTypeInfo {
        distro.supportsTypeHash ? typeInfo : typeInfo.withoutTypeHashes
    }
}

// MARK: - Action Protocol

/// Protocol for ROS 2 action types
public protocol ROS2Action: Sendable {
    associatedtype Goal: CDRCodable & Sendable
    associatedtype Result: CDRCodable & Sendable
    associatedtype Feedback: CDRCodable & Sendable
    /// The action name and the hashes of the default schema (Jazzy and later).
    static var typeInfo: ROS2ActionTypeInfo { get }

    /// The action name and the hashes this action has on the wire for `distro`: `nil` hashes
    /// where `distro` has no RIHS01 hashes (Humble). An action whose goal, result or feedback
    /// differs among distributions returns each distribution's hashes; every other action has
    /// the default implementation.
    static func typeInfo(for distro: ROS2Distro) -> ROS2ActionTypeInfo
}

extension ROS2Action {
    /// ``typeInfo``, without its hashes where `distro` has no RIHS01 hashes (Humble).
    public static func typeInfo(for distro: ROS2Distro) -> ROS2ActionTypeInfo {
        distro.supportsTypeHash ? typeInfo : typeInfo.withoutTypeHashes
    }
}

// MARK: - CDR Serialization Errors

/// Errors thrown by a generated `encode(to:)` when a field holds a value its IDL type cannot
/// carry, such as a fixed-size array of the wrong length. The message cannot be encoded.
public enum CDRSerializationError: Error, LocalizedError, Equatable, Sendable {
    /// A fixed-size array field (`T[N]`) holds a number of elements other than `N`.
    case invalidArrayLength(field: String, expected: Int, actual: Int)
    /// A bounded sequence field (`T[<=N]`) holds more than `N` elements.
    case sequenceTooLong(field: String, maximum: Int, actual: Int)
    /// A bounded string field (`string<=N`, or an element of an array or sequence of them) holds
    /// more than `N` UTF-8 bytes, which is how rosidl counts the bound.
    case stringTooLong(field: String, maximum: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidArrayLength(let field, let expected, let actual):
            return "Field '\(field)' is a fixed-size array of \(expected) elements but holds \(actual)"
        case .sequenceTooLong(let field, let maximum, let actual):
            return "Field '\(field)' is a sequence of at most \(maximum) elements but holds \(actual)"
        case .stringTooLong(let field, let maximum, let actual):
            return "Field '\(field)' is a string of at most \(maximum) bytes but holds \(actual)"
        }
    }
}
