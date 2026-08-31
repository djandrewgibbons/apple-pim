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

func buildReplyHTML(myText: String, attributionSender: String, originalHTML: String?, originalPlain: String) -> String {
    let myHTML = htmlEscapeForReply(myText).replacingOccurrences(of: "\n", with: "<br>\n")
    let trimmedHTML = originalHTML?.trimmingCharacters(in: .whitespacesAndNewlines)
    let quoted = trimmedHTML?.isEmpty == false
        ? trimmedHTML!
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
    guard aliases.isEmpty || aliases.contains(username.lowercased()) else {
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
