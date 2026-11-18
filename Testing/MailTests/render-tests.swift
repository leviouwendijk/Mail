import Foundation
import Mail
import Testing

enum RenderTests {
    static func textOnly() throws {
        let output = MailFixtures.renderer().rendered(try MailFixtures.message())
        let (head, body) = split(output)

        try Expect.contains(head, "From: Levi <levi@example.com>", "From with name")
        try Expect.contains(head, "To: jan@example.org", "To")
        try Expect.contains(head, "Subject: Afspraak", "Subject")
        try Expect.contains(head, "Message-ID: <fixed@example.com>", "Message-ID")
        try Expect.contains(head, "MIME-Version: 1.0", "MIME version")
        try Expect.contains(head, "Content-Type: text/plain; charset=utf-8", "Single text part")
        try Expect.equal(body, "Hello\r\n", "Body")
        try Expect.false(output.contains("multipart"), "No multipart for a single body")
    }

    static func alternativeWithAttachments() throws {
        let message = try MailFixtures.message(
            body: .alternative(text: "Hi", html: "<p>Hi <img src=\"cid:logo\"></p>"),
            attachments: [
                MailAttachment(filename: "factuur.pdf", contentType: "application/pdf", data: Data("pdf".utf8)),
                MailAttachment(filename: "logo.png", contentType: "image/png", data: Data("png".utf8), disposition: .inline(contentID: "logo")),
            ]
        )
        let part = MailFixtures.renderer().part(for: message)

        guard case .multipart("mixed", _, let mixed) = part.content,
              case .multipart("related", _, let related) = mixed[0].content,
              case .multipart("alternative", _, let alternative) = related[0].content
        else {
            throw TestFlowAssertionFailure(label: "structure", message: "expected mixed[related[alternative, inline], attachment]")
        }
        try Expect.equal(mixed.count, 2, "Mixed holds body and one attachment")
        try Expect.equal(related.count, 2, "Related holds body and one inline image")
        try Expect.equal(alternative.count, 2, "Alternative holds text and HTML")

        let output = MailFixtures.renderer().rendered(message)
        try Expect.contains(output, "Content-Disposition: attachment; filename=\"factuur.pdf\"", "Attachment disposition")
        try Expect.contains(output, "Content-ID: <logo>", "Inline content id")
        try Expect.contains(output, Data("pdf".utf8).base64EncodedString(), "Attachment data")
        try Expect.contains(output, "--b1--", "Closing boundary")
    }

    static func bcc() throws {
        let message = try MailFixtures.message(bcc: [try NamedAddress("secret@example.net")])
        let output = MailFixtures.renderer().rendered(message)

        try Expect.false(output.contains("secret@example.net"), "Bcc is not rendered")
        try Expect.false(output.contains("Bcc:"), "No Bcc header")
        try Expect.equal(
            message.recipients.map(\.raw),
            ["jan@example.org", "secret@example.net"],
            "Envelope still includes Bcc"
        )
    }

    private static func split(
        _ output: String
    ) -> (String, String) {
        let range = output.range(of: "\r\n\r\n")!
        return (String(output[..<range.lowerBound]), String(output[range.upperBound...]))
    }
}
