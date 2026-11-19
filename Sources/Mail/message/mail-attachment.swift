import Foundation
import IO
import Readers
import Writers

public struct MailAttachment: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case attachment
        /// Referenced from an HTML body as `cid:<contentID>`.
        case inline(contentID: String)
    }

    public var filename: String
    public var contentType: String
    public var data: Data
    public var disposition: Disposition

    public init(
        filename: String,
        contentType: String = "application/octet-stream",
        data: Data,
        disposition: Disposition = .attachment
    ) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.disposition = disposition
    }

    /// The file's bytes; the content type from its extension when not given.
    public static func file(
        at url: URL,
        contentType: String? = nil,
        disposition: Disposition = .attachment
    ) throws -> MailAttachment {
        MailAttachment(
            filename: url.lastPathComponent,
            contentType: contentType ?? Self.contentType(forExtension: url.pathExtension),
            data: try DataFileReader(url).read().data,
            disposition: disposition
        )
    }

    /// A MIME type for a file extension; `application/octet-stream` when unknown.
    public static func contentType(
        forExtension ext: String
    ) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "html", "htm": return "text/html"
        case "txt", "md": return "text/plain"
        case "csv": return "text/csv"
        case "ics": return "text/calendar"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "zip": return "application/zip"
        case "eml": return "message/rfc822"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    public var isInline: Bool {
        if case .inline = disposition {
            return true
        }
        return false
    }

    /// The sender-chosen `filename` reduced to one plain path component, so
    /// it cannot reach outside a directory; `attachment-<n>` when nothing is left.
    public func safeFilename(
        index: Int
    ) -> String {
        let last = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines).union(.controlCharacters))
        return trimmed.isEmpty ? "attachment-\(index + 1)" : trimmed
    }

    /// Writes the data into `directory` (created when missing) under its safe
    /// filename, or `name (2).ext`, `name (3).ext`… when taken. Never overwrites.
    @discardableResult
    public func save(
        in directory: URL,
        index: Int
    ) throws -> URL {
        let url = directory.appendingPathComponent(safeFilename(index: index))
        var candidate = url
        var number = 2
        while FileSystem.default.exists(candidate) {
            let ext = url.pathExtension
            candidate = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        try FileWriter(candidate).write(data)
        return candidate
    }
}
