import Foundation
import Testing
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

    @Test("Message-ID parser keeps each reference separate")
    func referenceParsing() {
        #expect(messageIDs(in: "<one@example.com> <two@example.com>") == [
            "<one@example.com>", "<two@example.com>",
        ])
    }
}
