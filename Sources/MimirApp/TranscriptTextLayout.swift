import AppKit

@MainActor
enum TranscriptTextLayout {
    // Match the transcript's native 16pt font and four-line collapsed layout.
    // TextKit counts wrapped lines rather than guessing from character count.
    static func isTruncated(_ text: String, width: CGFloat, fontSize: CGFloat = 16, maxLines: Int = 4) -> Bool {
        guard width.isFinite, width > 0, !text.isEmpty else { return false }
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, stop in
            lines += 1
            if lines > maxLines { stop.pointee = true }
        }
        return lines > maxLines
    }
}
