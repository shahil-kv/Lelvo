import LocalAuthentication

/// Face ID / Touch ID / Optic ID, or device passcode. Used for Locked folder.
enum BiometricGate {
    enum Failure: LocalizedError {
        case unavailable, cancelled, failed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "This device can't use Face ID, Touch ID or a passcode for Locked folder."
            case .cancelled: return nil
            case .failed: return "Couldn't unlock. Try again."
            }
        }
    }

    /// True when biometrics or device passcode can unlock Locked folder.
    static var canEvaluate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Short label for the unlock button ("Face ID", "Touch ID", "Optic ID", or "Passcode").
    static var biometryTitle: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "Passcode"
        @unknown default: return "Passcode"
        }
    }

    static func unlock(reason: String = "Unlock Locked folder") async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw Failure.unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if !ok { throw Failure.failed }
        } catch let err as LAError {
            switch err.code {
            case .userCancel, .appCancel, .systemCancel: throw Failure.cancelled
            default: throw Failure.failed
            }
        }
    }
}
