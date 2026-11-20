import Foundation
import MailConnection
import Milieu
import Testing

enum ConnectionTests {
    static func saslPlain() throws {
        let response = MailSASL.plain(MailCredentials(username: "levi", password: "secret"))
        try Expect.equal(response, "AGxldmkAc2VjcmV0", "Base64 of NUL user NUL password")
    }

    static func scriptedLiteral() async throws {
        let transport = ScriptedTransport(["* 1 FETCH (BODY[] {5}", "hello)"])
        try Expect.equal(try await transport.readLine(), "* 1 FETCH (BODY[] {5}", "Line before literal")
        try Expect.equal(try await transport.read(count: 5), Data("hello".utf8), "Literal bytes")
        try Expect.equal(try await transport.readLine(), ")", "Line after literal")
    }

    static func credentialResolution() async throws {
        let none = MailServerConfiguration(host: "mx.example.com", port: 465)
        try Expect.true(try await none.resolveCredentials(using: nil) == nil, "No authentication, no credentials")

        let plaintext = MailServerConfiguration(
            host: "localhost",
            port: 1025,
            security: .plaintext,
            authentication: MailAuthentication(username: "levi", password: CredentialReference("smtp"))
        )
        do {
            _ = try await plaintext.resolveCredentials(using: nil)
            throw TestFlowAssertionFailure(label: "plaintext-auth", message: "resolution should fail")
        } catch MailConnectionError.authenticationRequiresTLS {
        }

        let missing = MailServerConfiguration(
            host: "mx.example.com",
            port: 465,
            authentication: MailAuthentication(username: "levi", password: CredentialReference("smtp"))
        )
        do {
            _ = try await missing.resolveCredentials(using: nil)
            throw TestFlowAssertionFailure(label: "missing-provider", message: "resolution should fail")
        } catch MailConnectionError.missingCredentialProvider {
        }
    }
}
