import AppKit
import ApplicationServices
import MimirCore

/// The focused text field of an allowed app, read through Accessibility.
/// Adapted from Trecho's AccessibilityReader.
struct FocusedField {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let text: String
    /// Field frame in AX coordinates (top-left origin).
    let axFrame: CGRect

    func isSameField(as other: FocusedField) -> Bool {
        CFEqual(element, other.element)
    }
}

@MainActor
enum FocusedTextReader {
    /// Every Accessibility call gives up after this, so a hung app can't
    /// freeze Mimir's main thread (and with it the dictation hotkey).
    static let messagingTimeout: Float = 0.25
    static let maxTextLength = 8000

    /// The focused field, or nil when it must not be read. Order matters for
    /// privacy: app allowlist first, then the secure-field check, and only
    /// then anything that touches the app (Electron opt-in) or reads text.
    static func focusedField(policy: WritingAppPolicy) -> FocusedField? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              policy.allows(bundleID)
        else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        // Must come before the role check: until it is on, Electron reports no
        // text fields at all, so a password field can't be told apart. It
        // exposes structure only; the secure-field check below still blocks
        // reading any text.
        enableElectronAccessibility(appElement, pid: app.processIdentifier, bundleID: bundleID)

        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        guard let role = copyString(focused, kAXRoleAttribute),
              role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
        else { return nil }
        let subrole = copyString(focused, kAXSubroleAttribute)
        guard role != "AXSecureTextField", subrole != "AXSecureTextField",
              isSettable(focused, kAXValueAttribute)
        else { return nil }

        guard let text = copyString(focused, kAXValueAttribute),
              (text as NSString).length <= maxTextLength,
              let frame = axFrame(of: focused)
        else { return nil }
        return FocusedField(element: focused, pid: app.processIdentifier, bundleID: bundleID, text: text, axFrame: frame)
    }

    /// Electron apps (Slack) hide their text from Accessibility until asked.
    /// Only ever called for apps the policy allows.
    private static func enableElectronAccessibility(_ app: AXUIElement, pid: pid_t, bundleID: String) {
        let attribute = "AXManualAccessibility" as CFString
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID(),
              !CFEqual(value, kCFBooleanTrue) else { return }
        if AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue) == .success {
            electronEnabled[pid] = bundleID
        }
    }

    /// Apps where Mimir turned the Electron switch on (it was off before).
    private static var electronEnabled: [pid_t: String] = [:]

    /// Turns the Electron switch back off in apps no longer checked (check
    /// off, or app removed from the list): a full accessibility tree costs
    /// the app performance. Only apps Mimir itself switched on.
    static func disableElectronAccessibility(keeping isKept: (String) -> Bool) {
        for (pid, bundleID) in electronEnabled where !isKept(bundleID) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
            electronEnabled[pid] = nil
        }
    }

    static func currentText(of field: FocusedField) -> String? {
        copyString(field.element, kAXValueAttribute)
    }

    static func isStillFocused(_ field: FocusedField) -> Bool {
        let appElement = AXUIElementCreateApplication(field.pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, field.element)
    }

    // MARK: Geometry

    /// Screen rectangles (AX coordinates) of `range`, or [] when the editor
    /// doesn't report exact positions — never guessed from font metrics.
    static func rects(for range: NSRange, in field: FocusedField) -> [CGRect] {
        let direct = exactRects(element: field.element, source: field.text, range: range, within: field.axFrame)
        if !direct.isEmpty { return direct }
        // Chromium/Electron editors report the whole editor for a range, but
        // their AXStaticText children report exact glyph rectangles.
        let fragments = renderedFragments(of: field.element)
        let parts = fragmentParts(source: field.text, range: range, fragments: fragments.map(\.text))
        guard !parts.isEmpty else { return [] }
        var rects: [CGRect] = []
        for part in parts {
            let fragment = fragments[part.index]
            let exact = exactRects(element: fragment.element, source: fragment.text, range: part.range, within: field.axFrame)
            guard !exact.isEmpty else { return [] }
            rects.append(contentsOf: exact)
        }
        return merge(rects)
    }

    private static func exactRects(element: AXUIElement, source: String, range: NSRange, within frame: CGRect) -> [CGRect] {
        let ns = source as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= ns.length,
              ns.rangeOfComposedCharacterSequences(for: range) == range else { return [] }
        let tolerance = frame.insetBy(dx: -1, dy: -1)
        var rects: [CGRect] = []
        var previous: CGRect?
        var offset = range.location
        while offset < NSMaxRange(range) {
            let part = ns.rangeOfComposedCharacterSequence(at: offset)
            guard let (text, rect) = stringAndBounds(element, part),
                  text == ns.substring(with: part),
                  rect.width > 0, rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite,
                  tolerance.contains(rect), rect != previous
            else { return [] }
            if let last = rects.last, last.minY == rect.minY, last.height == rect.height {
                guard rect.minX <= last.maxX + 1, rect.maxX >= last.minX - 1 else { return [] }
                rects[rects.count - 1] = last.union(rect)
            } else {
                rects.append(rect)
            }
            previous = rect
            offset = NSMaxRange(part)
        }
        return rects
    }

    private static func stringAndBounds(_ element: AXUIElement, _ range: NSRange) -> (String, CGRect)? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var textRef: CFTypeRef?
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &textRef) == .success,
              let text = string(from: textRef),
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &boundsRef) == .success,
              let bounds = rect(from: boundsRef)
        else { return nil }
        return (text, bounds)
    }

    private struct Fragment {
        let element: AXUIElement
        let text: String
    }

    private static func renderedFragments(of element: AXUIElement) -> [Fragment] {
        var result: [Fragment] = []
        func visit(_ parent: AXUIElement, depth: Int) {
            guard depth <= 12, result.count < 400 else { return }
            for child in children(of: parent) {
                AXUIElementSetMessagingTimeout(child, messagingTimeout)
                if copyString(child, kAXRoleAttribute) == kAXStaticTextRole as String,
                   let text = copyString(child, kAXValueAttribute), !text.isEmpty {
                    result.append(Fragment(element: child, text: text))
                } else {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(element, depth: 1)
        return result
    }

    /// Splits `range` of `source` across the editor's rendered text pieces.
    /// Pieces are found in order; the gaps between them may only be line
    /// breaks or spaces (Slack separates paragraphs that way). Anything else
    /// means the pieces don't describe this text: no mapping, no underline.
    static func fragmentParts(source: String, range: NSRange, fragments: [String]) -> [(index: Int, range: NSRange)] {
        let ns = source as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length, !fragments.isEmpty else { return [] }
        var cursor = 0
        var placed: [(index: Int, range: NSRange)] = []
        for (index, fragment) in fragments.enumerated() {
            let length = (fragment as NSString).length
            guard length > 0 else { continue }
            let found = ns.range(of: fragment, options: .literal, range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { return [] }
            let gap = ns.substring(with: NSRange(location: cursor, length: found.location - cursor))
            guard gap.allSatisfy({ $0.isWhitespace || $0.isNewline }) else { return [] }
            placed.append((index, found))
            cursor = NSMaxRange(found)
        }
        var parts: [(index: Int, range: NSRange)] = []
        for (index, fragmentRange) in placed {
            let intersection = NSIntersectionRange(range, fragmentRange)
            if intersection.length > 0 {
                parts.append((index, NSRange(location: intersection.location - fragmentRange.location, length: intersection.length)))
            }
        }
        // The whole range must be covered by text pieces.
        guard parts.reduce(0, { $0 + $1.range.length }) == range.length else { return [] }
        return parts
    }

    private static func merge(_ rects: [CGRect]) -> [CGRect] {
        rects.reduce(into: []) { result, rect in
            if let last = result.last, last.minY == rect.minY, last.height == rect.height,
               rect.minX <= last.maxX + 1, rect.maxX >= last.minX - 1 {
                result[result.count - 1] = last.union(rect)
            } else {
                result.append(rect)
            }
        }
    }

    // MARK: Applying a fix

    /// Replaces exactly `range` with `replacement`, only if the field still
    /// holds `source`; the result must equal `expected`. Tries the AX text
    /// write first and falls back to typing (Electron ignores some writes).
    static func replace(range: NSRange, with replacement: String, in field: FocusedField, source: String, expected: String) -> Bool {
        let element = field.element
        guard isSettable(element, kAXSelectedTextRangeAttribute) else { return false }
        let previousSelection = copyRange(element, kAXSelectedTextRangeAttribute)

        func guardedWrite(_ write: () -> Bool) -> Bool {
            guard isStillFocused(field), currentText(of: field) == source,
                  setSelectedRange(element, range),
                  isStillFocused(field), currentText(of: field) == source,
                  copyRange(element, kAXSelectedTextRangeAttribute) == range
            else { return false }
            return write()
        }

        if isSettable(element, kAXSelectedTextAttribute),
           guardedWrite({ AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success }),
           currentText(of: field) == expected {
            return true
        }
        // Only type when the original text is still intact.
        guard currentText(of: field) == source,
              guardedWrite({ typeText(replacement, to: field.pid) })
        else {
            restoreSelection(previousSelection, field: field, source: source, target: range)
            return false
        }
        // Give the app time to handle every typed chunk before checking.
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.05)
            if currentText(of: field) == expected { return true }
        }
        return false
    }

    /// A keyboard event carries at most about 20 UTF-16 characters; longer
    /// text is cut. Split into chunks that never break a character apart.
    static let maxTypedChunk = 20

    static func typingChunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxTypedChunk {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func typeText(_ text: String, to pid: pid_t) -> Bool {
        let chunks = typingChunks(text)
        guard !chunks.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        for chunk in chunks {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return true
    }

    private static func restoreSelection(_ selection: NSRange?, field: FocusedField, source: String, target: NSRange) {
        guard let selection, isStillFocused(field), currentText(of: field) == source,
              copyRange(field.element, kAXSelectedTextRangeAttribute) == target else { return }
        _ = setSelectedRange(field.element, selection)
    }

    // MARK: AX helpers

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return string(from: ref)
    }

    private static func string(from ref: CFTypeRef?) -> String? {
        guard let ref else { return nil }
        if let value = ref as? String { return value }
        if let value = ref as? NSAttributedString { return value.string }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let values = ref as? [AnyObject] else { return [] }
        return values.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeDowncast($0, to: AXUIElement.self) : nil
        }
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let position = axValue(positionRef), let size = axValue(sizeRef)
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func copyRange(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = axValue(ref) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setSelectedRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func axValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(ref as AnyObject, to: AXValue.self)
    }

    private static func rect(from ref: CFTypeRef?) -> CGRect? {
        guard let value = axValue(ref) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }
}
