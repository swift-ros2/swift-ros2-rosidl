/// The types rosidl adds to the type description of a service (Iron and later), so the
/// generator can compute service-level and action-level RIHS01 hashes.
///
/// `rosidl_generator_type_description` describes a service `<pkg>/<kind>/<Name>` as a struct of
/// three nested fields — `request_message` (`<Name>_Request`), `response_message`
/// (`<Name>_Response`) and `event_message` (`<Name>_Event`) — where the event type is
/// `service_msgs/msg/ServiceEventInfo info`, `<Name>_Request[<=1] request` and
/// `<Name>_Response[<=1] response`. An action `<pkg>/action/<Name>` is a struct of `goal`,
/// `result`, `feedback`, `send_goal_service` (`<Name>_SendGoal`), `get_result_service`
/// (`<Name>_GetResult`) and `feedback_message` (`<Name>_FeedbackMessage`).
///
/// rmw_zenoh_cpp keys a service by the service type and this service-level hash, and an
/// action's `send_goal` / `get_result` services by the `<Name>_SendGoal` / `<Name>_GetResult`
/// service hashes.
///
/// `service_msgs/msg/ServiceEventInfo` and `builtin_interfaces/msg/Time` are fixed for every
/// distribution with type hashes, so they are built in here and callers do not have to pass
/// `service_msgs` as a dependency.
public enum ServiceDescription {
    /// `builtin_interfaces/msg/Time`, referenced by `ServiceEventInfo.stamp`.
    public static let time = MessageIR(
        package: "builtin_interfaces", typeName: "Time",
        fields: [
            FieldIR(ros2Name: "sec", swiftName: "sec", type: .primitive(.int32)),
            FieldIR(ros2Name: "nanosec", swiftName: "nanosec", type: .primitive(.uint32)),
        ])

    /// `service_msgs/msg/ServiceEventInfo`, the `info` field of every `<Service>_Event`.
    public static let serviceEventInfo = MessageIR(
        package: "service_msgs", typeName: "ServiceEventInfo",
        fields: [
            FieldIR(ros2Name: "event_type", swiftName: "eventType", type: .primitive(.uint8)),
            FieldIR(
                ros2Name: "stamp", swiftName: "stamp",
                type: .nested(package: "builtin_interfaces", typeName: "Time")),
            FieldIR(
                ros2Name: "client_gid", swiftName: "clientGid",
                type: .array(element: .primitive(.char), length: 16)),
            FieldIR(ros2Name: "sequence_number", swiftName: "sequenceNumber", type: .primitive(.int64)),
        ])

    /// The `<serviceName>_Event` type of a service whose halves are
    /// `<package>/<kind>/<serviceName>_Request` and `_Response`.
    public static func eventIR(package: String, kind: MessageKind, serviceName: String) -> MessageIR {
        MessageIR(
            package: package, typeName: "\(serviceName)_Event", kind: kind,
            fields: [
                FieldIR(
                    ros2Name: "info", swiftName: "info",
                    type: .nested(package: "service_msgs", typeName: "ServiceEventInfo")),
                FieldIR(
                    ros2Name: "request", swiftName: "request",
                    type: .sequence(
                        element: .nested(package: package, typeName: "\(serviceName)_Request"), upperBound: 1)),
                FieldIR(
                    ros2Name: "response", swiftName: "response",
                    type: .sequence(
                        element: .nested(package: package, typeName: "\(serviceName)_Response"), upperBound: 1)),
            ])
    }

    /// The service-level `<package>/<kind>/<serviceName>` type.
    public static func serviceIR(package: String, kind: MessageKind, serviceName: String) -> MessageIR {
        MessageIR(
            package: package, typeName: serviceName, kind: kind,
            fields: [
                FieldIR(
                    ros2Name: "request_message", swiftName: "requestMessage",
                    type: .nested(package: package, typeName: "\(serviceName)_Request")),
                FieldIR(
                    ros2Name: "response_message", swiftName: "responseMessage",
                    type: .nested(package: package, typeName: "\(serviceName)_Response")),
                FieldIR(
                    ros2Name: "event_message", swiftName: "eventMessage",
                    type: .nested(package: package, typeName: "\(serviceName)_Event")),
            ])
    }

    /// The action-level `<package>/action/<actionName>` type.
    public static func actionIR(package: String, actionName: String) -> MessageIR {
        func field(_ name: String, _ swiftName: String, _ suffix: String) -> FieldIR {
            FieldIR(
                ros2Name: name, swiftName: swiftName,
                type: .nested(package: package, typeName: "\(actionName)_\(suffix)"))
        }
        return MessageIR(
            package: package, typeName: actionName, kind: .action,
            fields: [
                field("goal", "goal", "Goal"),
                field("result", "result", "Result"),
                field("feedback", "feedback", "Feedback"),
                field("send_goal_service", "sendGoalService", "SendGoal"),
                field("get_result_service", "getResultService", "GetResult"),
                field("feedback_message", "feedbackMessage", "FeedbackMessage"),
            ])
    }

    /// Adds the `_Event` and service-level types of one service to `registry`, plus `Time` and
    /// `ServiceEventInfo` when the registry has no entry for them. The request and response
    /// halves must already be in the registry.
    public static func register(
        package: String, kind: MessageKind, serviceName: String,
        into registry: inout [String: MessageIR]
    ) {
        for base in [time, serviceEventInfo] where registry[base.rosTypeName] == nil {
            registry[base.rosTypeName] = base
        }
        for ir in [
            eventIR(package: package, kind: kind, serviceName: serviceName),
            serviceIR(package: package, kind: kind, serviceName: serviceName),
        ] {
            registry[ir.rosTypeName] = ir
        }
    }

    /// Adds an action's `<Name>_SendGoal` and `<Name>_GetResult` services (with their `_Event`
    /// types) and the action-level type to `registry`. The action's Goal / Result / Feedback and
    /// wrapper types must already be in the registry.
    public static func register(action: ActionIR, into registry: inout [String: MessageIR]) {
        for service in ["SendGoal", "GetResult"] {
            register(
                package: action.package, kind: .action, serviceName: "\(action.typeName)_\(service)",
                into: &registry)
        }
        let actionLevel = actionIR(package: action.package, actionName: action.typeName)
        registry[actionLevel.rosTypeName] = actionLevel
    }
}

/// The RIHS01 hashes of a service for one distribution: its request and response halves and
/// the service-level type (see ``ServiceDescription``). `nil` where a hash is unknown.
public struct ServiceHashes: Equatable, Sendable {
    /// Hash of `<pkg>/srv/<Service>_Request`.
    public var requestHash: String?
    /// Hash of `<pkg>/srv/<Service>_Response`.
    public var responseHash: String?
    /// Hash of the service-level `<pkg>/srv/<Service>` type.
    public var serviceHash: String?

    /// Creates the hashes of one distribution.
    public init(requestHash: String?, responseHash: String?, serviceHash: String?) {
        self.requestHash = requestHash
        self.responseHash = responseHash
        self.serviceHash = serviceHash
    }
}
