import Foundation
import Testing
import PIMConfig
@testable import MailCLI

@Suite("Reply drafts")
struct ReplyDraftTests {
    @Test("Reply-To wins over a spoofable sender display name")
    func replyToWins() throws {
        let envelope = try buildReplyDraftEnvelope(
            replyToAddress: "support@example.com",
            senderAddress: "attacker@example.net",
            originalTo: ["alias@example.com", "other@example.com"],
            originalCc: ["third@example.com", "other@example.com"],
            accountAddresses: ["me@example.com", "alias@example.com"],
            configuredUsername: "me@example.com"
        )
        #expect(envelope.from == "alias@example.com")
        #expect(envelope.to == ["support@example.com"])
        #expect(envelope.cc == ["other@example.com", "third@example.com"])
    }

    @Test("MIME parsing preserves formatted HTML for the quote")
    func formattedQuoteAndThreading() throws {
        let source = """
        From: Sender <sender@example.com>\r
        Message-ID: <parent@example.com>\r
        References: <root@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="B"\r
        \r
        --B\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        plain\r
        --B\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <p><b>formatted</b> =E2=80=94 text</p>\r
        --B--\r
        """
        let parsed = parseRFC822(data: Data(source.utf8))
        #expect(parsed.htmlContent?.contains("<b>formatted</b> — text") == true)
        let html = buildReplyHTML(
            myText: "Thanks",
            attributionSender: "Sender <sender@example.com>",
            originalHTML: parsed.htmlContent,
            originalPlain: parsed.content
        )
        let rendered = String(decoding: try MIMEMessage(
            from: "me@example.com",
            to: ["sender@example.com"],
            subject: "Re: Test",
            html: html,
            inReplyTo: "parent@example.com",
            references: messageIDs(in: parsed.header("References")) + ["parent@example.com"]
        ).render(), as: UTF8.self)
        #expect(rendered.contains("In-Reply-To: <parent@example.com>"))
        #expect(rendered.contains("References: <root@example.com> <parent@example.com>"))
        #expect(rendered.contains("<b>formatted</b>"))
    }

    @Test("Missing account addresses do not self-CC the sending alias")
    func noSelfCCWithoutAccountAddresses() throws {
        let envelope = try buildReplyDraftEnvelope(
            replyToAddress: nil,
            senderAddress: "support@example.com",
            originalTo: ["me@example.com", "other@example.com"],
            originalCc: [],
            accountAddresses: [],
            configuredUsername: "me@example.com"
        )
        #expect(envelope.from == "me@example.com")
        #expect(envelope.cc == ["other@example.com"])
    }

    @Test("Draft account resolution fails closed when aliases are unknown")
    func draftAccountFailsClosedWithoutAliases() {
        let config = PIMConfiguration(imap: IMAPDefaults(host: "imap.example.net", username: "me@example.net"))
        #expect(throws: CLIError.self) {
            _ = try resolveIMAPDraftAccount(config: config, accountAddresses: [])
        }
    }

    @Test("Draft account resolution rejects a username the account does not own")
    func draftAccountRejectsMismatchedUsername() {
        let config = PIMConfiguration(imap: IMAPDefaults(host: "imap.example.net", username: "agent@example.net"))
        #expect(throws: CLIError.self) {
            _ = try resolveIMAPDraftAccount(config: config, accountAddresses: ["victim@example.com"])
        }
    }

    @Test("Quoted HTML cannot restyle or hide the reply around it")
    func sanitizesQuotedHTML() {
        let hostile = """
        <!DOCTYPE html><html><head><style>div { display: none; }</style></head>
        <body><p>real <b>content</b></p><script>alert(1)</script></body></html>
        """
        let cleaned = sanitizeQuotedHTML(hostile)
        #expect(cleaned == "<p>real <b>content</b></p>")

        let html = buildReplyHTML(
            myText: "Thanks",
            attributionSender: "Sender <sender@example.com>",
            originalHTML: hostile,
            originalPlain: "real content"
        )
        #expect(!html.contains("display: none"))
        #expect(!html.contains("<script"))
        #expect(html.contains("<b>content</b>"))
    }

    @Test("Falls back to the plain-text body when the HTML part is only chrome")
    func fallsBackToPlainWhenHTMLIsEmptyAfterSanitizing() {
        let html = buildReplyHTML(
            myText: "Thanks",
            attributionSender: "Sender <sender@example.com>",
            originalHTML: "<html><head><style>p{color:red}</style></head><body></body></html>",
            originalPlain: "plain body"
        )
        #expect(html.contains("plain body"))
    }

    @Test("Message-ID parser keeps each reference separate")
    func referenceParsing() {
        #expect(messageIDs(in: "<one@example.com> <two@example.com>") == [
            "<one@example.com>", "<two@example.com>",
        ])
    }
}
