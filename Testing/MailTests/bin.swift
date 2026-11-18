import Foundation
import Testing

private enum MailTestingFailure: Error {
    case failed
}

@main
struct MailTestingMain {
    static func main() async throws {
        let reporter = PlainTextTestReporter(
            output: ClosureTestTextOutput { text in
                FileHandle.standardOutput.write(Data(text.utf8))
            }
        )
        let result = await TestRunner.run(
            MailTestSuite.suite,
            sink: reporter
        )
        if result.isFailure {
            throw MailTestingFailure.failed
        }
    }
}

enum MailTestSuite {
    static let suite = TestSuite(
        "mail",
        title: "Mail"
    ) {
        Test("address-accepts-valid") {
            try AddressTests.valid()
        }
        Test("address-rejects-invalid") {
            try AddressTests.invalid()
        }
        Test("quoted-printable-escapes-and-wraps") {
            try EncodingTests.quotedPrintable()
        }
        Test("encoded-word-only-when-needed") {
            try EncodingTests.encodedWord()
        }
        Test("display-name-quoting") {
            try EncodingTests.displayName()
        }
        Test("render-text-only") {
            try RenderTests.textOnly()
        }
        Test("render-alternative-with-attachments") {
            try RenderTests.alternativeWithAttachments()
        }
        Test("render-omits-bcc-keeps-envelope") {
            try RenderTests.bcc()
        }
        Test("parse-headers-addresses-dates") {
            try ParseTests.headers()
        }
        Test("parse-round-trips-rendered-message") {
            try ParseTests.roundTrip()
        }
        Test("parse-rfc2231-parameters") {
            try ParseTests.parameters()
        }
        Test("parse-legacy-charset") {
            try ParseTests.charset()
        }
        Test("imap-values-and-literals") {
            try await IMAPTests.values()
        }
        Test("imap-mailbox-names-utf7") {
            try IMAPTests.mailboxNames()
        }
        Test("imap-search-dsl") {
            try IMAPTests.searchQueries()
        }
        Test("imap-session-flow") {
            try await IMAPTests.session()
        }
        Test("imap-synchronizing-literal") {
            try await IMAPTests.synchronizingLiteral()
        }
        Test("imap-append-draft") {
            try await IMAPWriteTests.append()
        }
        Test("readable-text-from-html") {
            try IMAPWriteTests.readableText()
        }
        Test("gmail-search-syntax-and-threads") {
            try GmailTests.queries()
        }
        Test("gmail-syntax-refused-on-other-servers") {
            try await GmailTests.refusedElsewhere()
        }
        Test("gmail-thread-ids-and-labels") {
            try await GmailTests.threadsAndLabels()
        }
        Test("imap-command-failure") {
            try await IMAPTests.failure()
        }
        Test("frame-example-accounts") {
            try await FrameTests.example()
        }
        Test("frame-identity-signature") {
            try FrameTests.signature()
        }
        Test("frame-settings-from-environment") {
            try await FrameTests.environmentSettings()
        }
        Test("frame-split-server-logins") {
            try await FrameTests.splitServers()
        }
        Test("selector-parsing") {
            try SelectorTests.parsing()
        }
        Test("selector-matching-roles-and-groups") {
            try SelectorTests.matching()
        }
        Test("access-profile-matching") {
            try AccessTests.matching()
        }
        Test("access-profile-names") {
            try AccessTests.names()
        }
        Test("frame-rejects-invalid") {
            try FrameTests.invalid()
        }
        Test("starttls-smtp-upgrades-before-auth") {
            try await StartTLSTests.smtp()
        }
        Test("starttls-smtp-refuses-when-unoffered") {
            try await StartTLSTests.smtpRefused()
        }
        Test("starttls-imap-upgrades-and-refreshes") {
            try await StartTLSTests.imap()
        }
        Test("starttls-frame-icloud-defaults") {
            try StartTLSTests.frameDefaults()
        }
        Test("configuration-directory-merges-and-reloads") {
            try ConfigurationTests.directory()
        }
        Test("configuration-references-across-files") {
            try ConfigurationTests.crossFile()
        }
        Test("smtp-verify-logs-in-without-sending") {
            try await ConfigurationTests.smtpVerify()
        }
        Test("sasl-plain-response") {
            try ConnectionTests.saslPlain()
        }
        Test("transport-reads-literal-bytes") {
            try await ConnectionTests.scriptedLiteral()
        }
        Test("credentials-refuse-plaintext-and-missing-provider") {
            try await ConnectionTests.credentialResolution()
        }
        Test("reply-multi-line") {
            try await SessionTests.multiLineReply()
        }
        Test("dot-stuffing") {
            try SessionTests.dotStuffing()
        }
        Test("session-submits-with-auth") {
            try await SessionTests.submitWithAuth()
        }
        Test("session-reports-rejected-recipient") {
            try await SessionTests.partialRejection()
        }
        Test("session-fails-when-all-rejected") {
            try await SessionTests.allRejected()
        }
        Test("session-requires-auth-plain") {
            try await SessionTests.authUnsupported()
        }
    }
}
