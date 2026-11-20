import Foundation
import Mail
import Testing

enum ParseTests {
    static func headers() throws {
        let raw = Data((
            "Subject: =?UTF-8?Q?Caf=C3=A9_om?=\r\n" +
            " =?UTF-8?B?dGllbg==?= uur\r\n" +
            "From: \"Vries, Jan de\" <jan@example.org>\r\n" +
            "To: =?UTF-8?B?Wm/Dqw==?= <zoe@example.org>, team: a@example.org, b@example.org;, bare@example.net\r\n" +
            "Date: Tue, 17 Nov 2026 09:30:00 +0100 (CET)\r\n" +
            "Message-ID: <abc@example.org>\r\n" +
            "\r\n" +
            "Body\r\n"
        ).utf8)
        let message = ReceivedMessage(parsing: raw)

        try Expect.equal(message.subject, "Café omtien uur", "Folded encoded words joined")
        try Expect.equal(message.from.first?.name, "Vries, Jan de", "Quoted name with comma")
        try Expect.equal(message.to.map(\.address.raw), ["zoe@example.org", "a@example.org", "b@example.org", "bare@example.net"], "Groups flattened")
        try Expect.equal(message.to.first?.name, "Zoë", "Encoded display name")
        try Expect.equal(message.messageID, "abc@example.org", "Message-ID without brackets")
        try Expect.equal(message.date, Date(timeIntervalSince1970: 1_794_904_200), "Date with comment")
        try Expect.equal(message.text, "Body\r\n", "Default text/plain body")
    }

    static func roundTrip() throws {
        let original = try MailFixtures.message(
            body: .alternative(text: "Hallo Jan,\nTot morgen.", html: "<p>Hallo Jan, één</p>"),
            attachments: [
                MailAttachment(filename: "factuur €.pdf", contentType: "application/pdf", data: Data((0..<200).map { UInt8($0) })),
                MailAttachment(filename: "logo.png", contentType: "image/png", data: Data("png".utf8), disposition: .inline(contentID: "logo")),
            ]
        )
        let parsed = ReceivedMessage(parsing: MailFixtures.renderer().data(original))

        try Expect.equal(parsed.subject, "Afspraak", "Subject")
        try Expect.equal(parsed.from, [original.from], "From")
        try Expect.equal(parsed.text, "Hallo Jan,\r\nTot morgen.", "Text body")
        try Expect.equal(parsed.html, "<p>Hallo Jan, één</p>", "HTML body")
        try Expect.equal(parsed.attachments.count, 2, "Both attachments")
        try Expect.equal(parsed.attachments.first { $0.filename == "factuur €.pdf" }?.data, original.attachments[0].data, "Binary attachment intact")
        try Expect.equal(
            parsed.attachments.first { $0.filename == "logo.png" }?.disposition,
            .inline(contentID: "logo"),
            "Inline content id"
        )
    }

    static func parameters() throws {
        let value = MIMEHeaderValue.parse("attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf; size=12")
        try Expect.equal(value.value, "attachment", "Disposition")
        try Expect.equal(value["filename"], "résumé.pdf", "RFC 2231 filename")
        try Expect.equal(value["size"], "12", "Plain parameter")

        let continued = MIMEHeaderValue.parse("application/pdf; name*0=\"long \"; name*1=\"name.pdf\"")
        try Expect.equal(continued["name"], "long name.pdf", "Continuations joined")
    }

    static func charset() throws {
        let raw = Data((
            "Content-Type: text/plain; charset=iso-8859-1\r\n" +
            "Content-Transfer-Encoding: quoted-printable\r\n" +
            "\r\n" +
            "Caf=E9 op de ho=\r\nek"
        ).utf8)
        try Expect.equal(ReceivedMessage(parsing: raw).text, "Café op de hoek", "Latin-1 and soft breaks")
    }

    /// Saving keeps sender names inside the directory and never overwrites.
    static func savesAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let invoice = MailAttachment(filename: "factuur.pdf", contentType: "application/pdf", data: Data("pdf".utf8))
        let first = try invoice.save(in: root, index: 0)
        let second = try invoice.save(in: root, index: 0)
        try Expect.equal(first.lastPathComponent, "factuur.pdf", "Keeps the name")
        try Expect.equal(second.lastPathComponent, "factuur (2).pdf", "Never overwrites")

        let escaping = MailAttachment(filename: "../../.ssh/config", data: Data("x".utf8))
        let kept = try escaping.save(in: root, index: 1)
        try Expect.equal(kept.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path, "Stays in the directory")
        try Expect.equal(kept.lastPathComponent, "config", "Only the last component")

        let unnamed = MailAttachment(filename: "..", data: Data("x".utf8))
        try Expect.equal(unnamed.safeFilename(index: 2), "attachment-3", "Falls back to a numbered name")
    }
}
