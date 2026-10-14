/// Per-distro hashes for an action's eight contained type descriptions and its two services.
///
/// The eight member hashes are the wrapper / block hashes that either travel
/// on the wire (the five wrappers) or describe the user-facing goal / result
/// / feedback payloads. The two service hashes describe `<Type>_SendGoal` and
/// `<Type>_GetResult` (see ``ServiceDescription``): rmw_zenoh_cpp keys the
/// action's `send_goal` and `get_result` services by them. The action-level
/// `<pkg>/action/<Type>` hash is not stored: no wire codec reads it.
public struct ActionHashes: Equatable, Sendable {
    public var goalHash: String
    public var resultHash: String
    public var feedbackHash: String
    public var sendGoalRequestHash: String
    public var sendGoalResponseHash: String
    public var getResultRequestHash: String
    public var getResultResponseHash: String
    public var feedbackMessageHash: String
    /// Hash of the `<Type>_SendGoal` service.
    public var sendGoalServiceHash: String?
    /// Hash of the `<Type>_GetResult` service.
    public var getResultServiceHash: String?

    public init(
        goalHash: String,
        resultHash: String,
        feedbackHash: String,
        sendGoalRequestHash: String,
        sendGoalResponseHash: String,
        getResultRequestHash: String,
        getResultResponseHash: String,
        feedbackMessageHash: String,
        sendGoalServiceHash: String? = nil,
        getResultServiceHash: String? = nil
    ) {
        self.goalHash = goalHash
        self.resultHash = resultHash
        self.feedbackHash = feedbackHash
        self.sendGoalRequestHash = sendGoalRequestHash
        self.sendGoalResponseHash = sendGoalResponseHash
        self.getResultRequestHash = getResultRequestHash
        self.getResultResponseHash = getResultResponseHash
        self.feedbackMessageHash = feedbackMessageHash
        self.sendGoalServiceHash = sendGoalServiceHash
        self.getResultServiceHash = getResultServiceHash
    }
}

/// Distro-neutral intermediate representation of a single ROS 2 action type.
///
/// Bundles the three user-defined IRs (`goal` / `result` / `feedback`) with
/// the five wrapper IRs synthesized per the rcl action protocol. All eight
/// IRs are regular ``MessageIR``s (``MessageKind/action``) so the existing
/// emitter / RIHS01 code reuses untouched.
public struct ActionIR: Equatable, Sendable {
    public let package: String  // "example_interfaces"
    public let typeName: String  // "Fibonacci"

    public var goal: MessageIR
    public var result: MessageIR
    public var feedback: MessageIR

    public var sendGoalRequest: MessageIR
    public var sendGoalResponse: MessageIR
    public var getResultRequest: MessageIR
    public var getResultResponse: MessageIR
    public var feedbackMessage: MessageIR

    /// Per-distro hashes for each of the eight member IRs.
    public var perDistroHashes: [String: ActionHashes] = [:]

    public init(
        package: String,
        typeName: String,
        goal: MessageIR,
        result: MessageIR,
        feedback: MessageIR,
        sendGoalRequest: MessageIR,
        sendGoalResponse: MessageIR,
        getResultRequest: MessageIR,
        getResultResponse: MessageIR,
        feedbackMessage: MessageIR,
        perDistroHashes: [String: ActionHashes] = [:]
    ) {
        self.package = package
        self.typeName = typeName
        self.goal = goal
        self.result = result
        self.feedback = feedback
        self.sendGoalRequest = sendGoalRequest
        self.sendGoalResponse = sendGoalResponse
        self.getResultRequest = getResultRequest
        self.getResultResponse = getResultResponse
        self.feedbackMessage = feedbackMessage
        self.perDistroHashes = perDistroHashes
    }

    /// "example_interfaces/action/Fibonacci"
    public var rosActionName: String { "\(package)/action/\(typeName)" }
}
