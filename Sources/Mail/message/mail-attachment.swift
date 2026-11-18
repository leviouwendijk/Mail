import Foundation
import Readers

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

    public static func file(
        at url: URL,
        contentType: String = "application/octet-stream",
        disposition: Disposition = .attachment
    ) throws -> MailAttachment {
        MailAttachment(
            filename: url.lastPathComponent,
            contentType: contentType,
            data: try DataFileReader(url).read().data,
            disposition: disposition
        )
    }

    public var isInline: Bool {
        if case .inline = disposition {
            return true
        }
        return false
    }
}
