import AppKit
import ApplicationServices

/// Thin, non-throwing wrappers over the AX attribute API.
///
/// Every one of these returns nil rather than an error: a menu bar item can vanish
/// between being enumerated and being read (its app quit), and at this layer that is
/// ordinary, not exceptional.
public enum AX {

    /// Ceiling for a single AX message.
    ///
    /// This is not a micro-optimisation. Without an explicit timeout every read uses the
    /// system default of several seconds, and any process that does not answer promptly
    /// stalls the caller for that long. Two of Mail's WebKit content processes were enough
    /// to make a full scan take 4.7s; bounding messages at 100ms brought that to 225ms
    /// while finding exactly the same items, because every app that actually owns a status
    /// item answers well inside it.
    public static let messagingTimeout: Float = 0.1

    /// An application element that will not stall the caller.
    ///
    /// Always prefer this over `AXUIElementCreateApplication` directly.
    public static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Bound an element obtained from a children array, which carries no timeout of its own.
    @discardableResult
    public static func bound(_ element: AXUIElement, timeout: Float = messagingTimeout) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    // MARK: Attributes

    public static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    public static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    /// Non-empty `AXTitle`, falling back to non-empty `AXDescription`.
    ///
    /// Most third-party status items supply neither — of the 32 items enumerated on the
    /// development machine only 6 had a usable label — so callers must treat nil as normal
    /// and fall back to the owning application's name.
    public static func label(_ element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
            if let value = string(element, attribute), !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: Geometry

    private static func boxedValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    public static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = boxedValue(element, kAXPositionAttribute as String),
              let sizeValue = boxedValue(element, kAXSizeAttribute as String)
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    // MARK: Actions

    public static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Outcome of asking an element to perform an action.
    public enum ActionOutcome {
        /// The app performed the action and replied.
        case completed
        /// The app accepted the action but never replied before the timeout.
        ///
        /// For a menu bar item this is the *expected* result, not a failure: the app opens
        /// its menu and sits in a nested menu tracking loop, so it cannot answer the AX
        /// message until that menu closes.
        case dispatched
        case failed(AXError)

        public var succeeded: Bool {
            switch self {
            case .completed, .dispatched: return true
            case .failed: return false
                }
        }
    }

    /// Perform an action without ever blocking longer than `timeout`.
    ///
    /// The timeout is mandatory for menu-opening elements. Without it this call does not
    /// return until the user dismisses the foreign menu, which on the main thread means the
    /// whole app is frozen for that entire time.
    public static func perform(
        _ element: AXUIElement,
        _ action: String,
        timeout: Float = 0.3
    ) -> ActionOutcome {
        AXUIElementSetMessagingTimeout(element, timeout)
        let result = AXUIElementPerformAction(element, action as CFString)
        switch result {
        case .success: return .completed
        case .cannotComplete: return .dispatched
        default: return .failed(result)
        }
    }

    // MARK: Trust

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Checks trust, optionally raising the system prompt that deep-links to
    /// Privacy & Security → Accessibility.
    @discardableResult
    public static func checkTrust(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
