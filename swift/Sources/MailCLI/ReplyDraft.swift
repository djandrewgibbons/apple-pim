import Foundation
import PIMConfig

struct ReplyDraftEnvelope: Equatable {
    let from: String
    let to: [String]
    let cc: [String]
}

func buildReplyDraftEnvelope(
    replyToAddress: String?,
    senderAddress: String,
    originalTo: [String],
    originalCc: [String],
    accountAddresses: [String],
    configuredUsername: String?
) throws -> ReplyDraftEnvelope {
    let selfAddresses = Set(accountAddresses.map { $0.lowercased() })
    let target = (replyToAddress?.isEmpty == false ? replyToAddress : senderAddress)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard target.contains("@") else {
        throw CLIError.invalidInput("could not determine a structured Reply-To or sender address")
    }

    let addressedAlias = (originalTo + originalCc).first {
        selfAddresses.contains($0.lowercased())
    }
    let from = addressedAlias
        ?? accountAddresses.first
        ?? configuredUsername
        ?? ""
    guard from.contains("@") else {
        throw CLIError.invalidInput("could not determine the source account address for the draft")
    }

    var seen = selfAddresses
    seen.insert(from.lowercased())
    seen.insert(target.lowercased())
    var cc: [String] = []
    for address in originalTo + originalCc {
        let key = address.lowercased()
        guard address.contains("@"), !seen.contains(key) else { continue }
        seen.insert(key)
        cc.append(address)
    }
    return ReplyDraftEnvelope(from: from, to: [target], cc: cc)
}

func htmlEscapeForReply(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// The quoted body comes from an untrusted sender but is embedded in the draft the
/// user reviews. A `<style>` block or a full `<html>` document would otherwise escape
/// the blockquote and restyle or hide the user's own reply text.
func sanitizeQuotedHTML(_ html: String) -> String {
    var result = html
    for element in ["script", "style", "head", "title"] {
        result = result.replacingOccurrences(
            of: "<\(element)\\b[^>]*>[\\s\\S]*?</\(element)\\s*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    if let body = firstCapture(in: result, pattern: "<body\\b[^>]*>([\\s\\S]*)</body\\s*>") {
        result = body
    }
    for pattern in [
        "<![^>]*>",
        "</?html\\b[^>]*>",
        "</?body\\b[^>]*>",
        "<(link|meta|base)\\b[^>]*>",
        "</?(script|style|head|title)\\b[^>]*>",
    ] {
        result = result.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func firstCapture(in value: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(value.startIndex..., in: value)
    guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges > 1 else { return nil }
    return Range(match.range(at: 1), in: value).map { String(value[$0]) }
}

func buildReplyHTML(myText: String, attributionSender: String, originalHTML: String?, originalPlain: String) -> String {
    let myHTML = htmlEscapeForReply(myText).replacingOccurrences(of: "\n", with: "<br>\n")
    let sanitizedHTML = originalHTML.map(sanitizeQuotedHTML)
    let quoted = sanitizedHTML?.isEmpty == false
        ? sanitizedHTML!
        : htmlEscapeForReply(originalPlain).replacingOccurrences(of: "\n", with: "<br>\n")
    return """
    <div>\(myHTML)</div>
    <br>
    <div>On \(htmlEscapeForReply(attributionSender)) wrote:</div>
    <blockquote type="cite" style="margin:0 0 0 0.8ex;border-left:2px solid #cccccc;padding-left:1ex;">
    \(quoted)
    </blockquote>
    """
}

func replySubject(_ subject: String) -> String {
    subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
}

func messageIDs(in header: String?) -> [String] {
    guard let header else { return [] }
    let pattern = #"<[^<>\s]+>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(header.startIndex..., in: header)
    return regex.matches(in: header, range: range).compactMap {
        Range($0.range, in: header).map { String(header[$0]) }
    }
}

struct ResolvedIMAPDraft {
    let host: String
    let port: Int
    let username: String
    let password: String
    let folder: String
}

func resolveIMAPDraftAccount(config: PIMConfiguration, accountAddresses: [String]) throws -> ResolvedIMAPDraft {
    let smtpHost = config.smtp?.host
    let host: String
    if let configured = config.imap?.host, !configured.isEmpty {
        host = configured
    } else if smtpHost == nil || smtpHost == "smtp.mail.me.com" || smtpHost?.hasSuffix(".mail.me.com") == true {
        host = "imap.mail.me.com"
    } else {
        throw CLIError.invalidInput("reply --draft requires imap.host for non-iCloud accounts")
    }

    guard let username = config.imap?.username ?? config.smtp?.username else {
        throw CLIError.invalidInput("reply --draft requires imap.username or smtp.username")
    }
    let aliases = Set(accountAddresses.map { $0.lowercased() })
    guard !aliases.isEmpty else {
        throw CLIError.invalidInput("could not determine the source Mail account's addresses; refusing to draft without verifying the configured IMAP identity")
    }
    guard aliases.contains(username.lowercased()) else {
        throw CLIError.invalidInput("configured IMAP username does not match the source Mail account")
    }

    let secretKey = config.imap?.secretKey ?? config.smtp?.secretKey ?? "smtp.icloud.password"
    guard let password = SecretsStore.resolve(secretKey) else {
        throw CLIError.invalidInput("no IMAP password found for key '\(secretKey)'; set it with mail-cli secrets set \(secretKey)")
    }
    return ResolvedIMAPDraft(
        host: host,
        port: config.imap?.port ?? 993,
        username: username,
        password: password,
        folder: config.imap?.draftsFolder ?? "Drafts"
    )
}
