import Foundation

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

/// Turns a raw Whistle transcript into what gets typed: drops filler words, applies
/// "new line" / "new paragraph" voice commands and expands snippets.
struct TextCleaner {
    var removeFillers = true
    var voiceCommands = true
    var snippets: [Snippet] = []

    func clean(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if removeFillers { text = Self.stripFillers(text) }
        if voiceCommands { text = Self.applyVoiceCommands(text) }
        text = Self.applySnippets(text, snippets)
        return Self.tidy(text)
    }

    // um, umm, uhm, uh, uhh, ah, erm, hm, hmm, äh, ähm, euh. Not "er" or "eh": those are real words in German and Spanish.
    private static let filler = try! NSRegularExpression(
        pattern: #"([,;:]?)[ \t]*(?<![\p{L}\p{N}'’-])(?:u+h*m+|u+h+|a+h+|e+r+m+|h+m+|ä+h+m*|e+u+h+)(?![\p{L}\p{N}'’-])([,.!?;:]?)[ \t]*"#,
        options: [.caseInsensitive])

    static func stripFillers(_ input: String) -> String {
        var text = input
        let matches = filler.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        // Right to left, so earlier match ranges stay valid while later text changes.
        for match in matches.reversed() {
            let current = text as NSString
            let pre = current.substring(with: match.range(at: 1))
            let post = current.substring(with: match.range(at: 2))
            let before = current.substring(to: match.range.location)
            var after = current.substring(from: NSMaxRange(match.range))

            let beforeTrimmed = before.trimmingCharacters(in: .whitespaces)
            let atSentenceStart = beforeTrimmed.isEmpty || ".!?\n".contains(beforeTrimmed.last!)
            let endsSentence = !post.isEmpty && ".!?".contains(post)
            let next = after.first { !$0.isWhitespace }

            let replacement: String
            if atSentenceStart {
                // "Thanks. Um, so we..." -> "Thanks. So we..."
                replacement = beforeTrimmed.isEmpty || before.hasSuffix("\n") ? "" : " "
                if let index = after.firstIndex(where: { !$0.isWhitespace }), after[index].isLowercase {
                    after.replaceSubrange(index...index, with: after[index].uppercased())
                }
            } else if next == nil {
                // "...the numbers, um." -> "...the numbers."
                replacement = endsSentence ? post : ""
            } else if endsSentence {
                replacement = post + " "
            } else if pre == ";" || pre == ":" {
                replacement = pre + " "
            } else if !pre.isEmpty || !post.isEmpty {
                // "Can we, uh, meet" -> "Can we meet", but "Hey Sarah, um, I wanted" -> "Hey Sarah, I wanted".
                replacement = next!.isLowercase ? " " : ", "
            } else {
                replacement = " "
            }
            text = before + replacement + after
        }
        return text
    }

    private static let command = try! NSRegularExpression(
        pattern: #"([.!?,;:]?)[ \t]*(?<![\p{L}\p{N}])new[ \t]+(line|paragraph)(?![\p{L}\p{N}])([.!?,;:]?)[ \t]*"#,
        options: [.caseInsensitive])

    static func applyVoiceCommands(_ input: String) -> String {
        var text = input
        let matches = command.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        for match in matches.reversed() {
            let current = text as NSString
            let leading = current.substring(with: match.range(at: 1))
            let kind = current.substring(with: match.range(at: 2)).lowercased()
            let trailing = current.substring(with: match.range(at: 3))
            let before = current.substring(to: match.range.location)
            var after = current.substring(from: NSMaxRange(match.range))
            // Only a command when it stands apart from the sentence ("Thanks. New paragraph."),
            // never inside one ("we need a new line of credit").
            let beforeTrimmed = before.trimmingCharacters(in: .whitespaces)
            let standsAlone = !leading.isEmpty || beforeTrimmed.isEmpty || before.hasSuffix("\n")
                || !trailing.isEmpty || after.trimmingCharacters(in: .whitespaces).isEmpty
            guard standsAlone else { continue }
            if let index = after.firstIndex(where: { !$0.isWhitespace }), after[index].isLowercase {
                after.replaceSubrange(index...index, with: after[index].uppercased())
            }
            text = before + leading + (kind == "line" ? "\n" : "\n\n") + after
        }
        return text
    }

    static func applySnippets(_ input: String, _ snippets: [Snippet]) -> String {
        var text = input
        for snippet in snippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            // A dictation that is only the trigger ("My email.") becomes exactly the expansion.
            let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,; \n"))
            if bare.caseInsensitiveCompare(trigger) == .orderedSame { return snippet.expansion }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: trigger) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion))
        }
        return text
    }

    static func tidy(_ input: String) -> String {
        var text = input
        for (pattern, template) in [
            (#"[ \t]{2,}"#, " "),
            (#"[ \t]+([,.!?;:])"#, "$1"),
            (#"([,;:])[ \t]*([,;:.!?])"#, "$2"),
            (#"[ \t]+\n"#, "\n"),
            (#"\n[ \t]+"#, "\n"),
            (#"^[ \t,;:]+"#, ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
