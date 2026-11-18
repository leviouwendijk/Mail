import Foundation

public extension ReceivedMessage {
    /// The text body, or the HTML body reduced to text when there is no text part.
    var readableText: String? {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return html.map { Self.plainText(fromHTML: $0) }
    }

    /// Drops scripts, styles and tags, keeps line structure, and decodes common entities.
    static func plainText(
        fromHTML html: String
    ) -> String {
        var text = html
        for (pattern, replacement) in [
            ("(?is)<(script|style|head)[^>]*>.*?</\\1>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|tr|li|h[1-6]|blockquote)>", "\n"),
            ("(?i)<li[^>]*>", "• "),
            ("<[^>]+>", ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
