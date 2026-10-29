import DesignSystem
import Foundation
import Testing

/// The iOS copy check (DESIGN.md §9.3, §11.14): crypto words may appear only in
/// the balance disclosure and its sheet, About and legal, Technical details
/// and Developer settings. Scans every string literal in the app's UI modules
/// (the sources are next to this file; tests run on the Simulator, which can
/// read them) and fails on a banned term anywhere else.
///
/// Rules:
/// - Words, case-insensitive: USDC, wallet, blockchain, Privy, gas,
///   transaction(s), hash, Monad. "Base" as a capitalized word. `0x` followed
///   by a hex digit.
/// - Interpolations (`\(…)`) are code, not copy, and are removed first.
/// - Comment lines and everything from a file's first preview
///   (`#Preview` or a `…Preview` struct) to its end are skipped: previews
///   never ship in a screen.
///
/// The same files are also checked for em dashes and "!" in strings (DESIGN
/// W3), and for test-money text outside `#if DEBUG` (SPEC §1.11 AC-7 check 1).
@Suite("Copy check")
struct CopyCheckTests {
    /// Folders whose string literals can reach the screen, each enumerated
    /// recursively, so a new file is scanned as soon as it exists.
    static let modules = [
        "AppFeature", "DesignSystem", "FeatureAuth", "FeatureHome",
        "FeatureSavings", "FeatureCircles", "FeatureActivity", "FeatureAccount",
        "FeatureStreaks", "FeatureLearn", "Domain",
    ]

    /// Paths under Sources/ that hold server keys and wire values, never copy.
    static let skippedPathPrefixes = ["Domain/DTO/"]

    /// Files `noEmojiInAppStrings` skips: the 12 curated goal emoji. Every
    /// other check scans them.
    static let emojiExemptFiles: Set<String> = ["Domain/Vocabulary.swift"]

    /// Where DESIGN.md §9.3 allows crypto words (paths under Sources/).
    static let allowedFiles: Set<String> = [
        "DesignSystem/Components/Feedback.swift", // Disclosure footer and "About your balance"
        "FeatureAccount/AboutView.swift", // About and legal
        "FeatureAccount/TechnicalDetailsView.swift", // Technical details
        "AppFeature/DeveloperSettingsView.swift", // Developer settings (Debug only)
    ]

    static let bannedWords = ["usdc", "wallet", "blockchain", "privy", "gas", "transaction", "transactions", "hash", "monad"]

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/MoolahubKit/Sources")
    }

    /// Every Swift file of `modules` (recursively, minus
    /// `skippedPathPrefixes`): its path under Sources/ and its URL.
    static func sourceFiles() -> [(path: String, url: URL)] {
        let root = sourcesRoot
        var files: [(path: String, url: URL)] = []
        for module in modules {
            let folder = root.appendingPathComponent(module)
            let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            for file in found {
                let path = String(file.path.dropFirst(root.path.count + 1))
                guard !skippedPathPrefixes.contains(where: { path.hasPrefix($0) }) else { continue }
                files.append((path, file))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The scan reaches every module's subfolders and Domain outside `DTO/`.
    @Test func scanCoversTheModulesRecursivelyAndSkipsOnlyDomainDTO() {
        let paths = Self.sourceFiles().map(\.path)
        for expected in [
            "DesignSystem/Components/Feedback.swift", "Domain/Streaks.swift", "Domain/Vocabulary.swift",
            "FeatureStreaks/StreakScreen.swift", "FeatureLearn/LearnListView.swift",
        ] {
            #expect(paths.contains(expected), "\(expected) is not scanned")
        }
        #expect(!paths.contains { $0.hasPrefix("Domain/DTO/") })
        #expect(Self.modules.allSatisfy { module in paths.contains { $0.hasPrefix(module + "/") } })
    }

    @Test func noCryptoWordsOutsideTheAllowedScreens() throws {
        var scanned = 0
        var findings: [String] = []
        for file in Self.sourceFiles() where !Self.allowedFiles.contains(file.path) {
            scanned += 1
            let text = try String(contentsOf: file.url, encoding: .utf8)
            findings += Self.findings(in: text, file: file.path)
        }
        #expect(scanned > 40, "found only \(scanned) source files under \(Self.sourcesRoot.path)")
        #expect(findings.isEmpty, "banned words in user-facing strings:\n\(findings.joined(separator: "\n"))")
    }

    /// The checker itself catches what it should and lets through what it should.
    @Test func checkerCatchesBannedWords() {
        #expect(!Self.findings(in: #"Text("Your wallet address")"#, file: "x").isEmpty)
        #expect(!Self.findings(in: #"Text("Held as USDC")"#, file: "x").isEmpty)
        #expect(!Self.findings(in: #"Text("On Base")"#, file: "x").isEmpty)
        #expect(!Self.findings(in: #"Text("Sent to 0xabc")"#, file: "x").isEmpty)
        #expect(Self.findings(in: #"Text("Balance \(wallet.available)")"#, file: "x").isEmpty)
        #expect(Self.findings(in: #"// the wallet is never shown"#, file: "x").isEmpty)
        #expect(Self.findings(in: "Text(\"Done\")\n#Preview { Text(\"Network: Base\") }", file: "x").isEmpty)
        #expect(Self.findings(in: #"Text("Database")"#, file: "x").isEmpty)
    }

    // MARK: Emoji (DESIGN.md v2 A7.4, W1, U7)

    /// Emoji are identity art only (founder decision 2): they may appear inside
    /// `EmojiTile`, never in the app's own strings. Scans every string literal
    /// of the same modules (escapes such as `\u{1F3AF}` decoded) with the
    /// predicate `EmojiIdentity` uses. The 12 curated goal emoji live in
    /// `Domain/Vocabulary.swift`, which this check alone skips.
    @Test func noEmojiInAppStrings() throws {
        var scanned = 0
        var findings: [String] = []
        for file in Self.sourceFiles() where !Self.emojiExemptFiles.contains(file.path) {
            scanned += 1
            let text = try String(contentsOf: file.url, encoding: .utf8)
            findings += Self.emojiFindings(in: text, file: file.path)
        }
        #expect(scanned > 40, "found only \(scanned) source files under \(Self.sourcesRoot.path)")
        #expect(findings.isEmpty, "emoji in app strings (identity art belongs in EmojiTile only):\n\(findings.joined(separator: "\n"))")
    }

    /// The emoji checker catches the text-default emoji a scan for
    /// `Emoji_Presentation` alone misses, and agrees with `EmojiIdentity`.
    @Test func emojiCheckerCatchesTextDefaultEmoji() {
        for emoji in ["\u{2764}\u{FE0F}", "\u{2708}\u{FE0F}", "1\u{FE0F}\u{20E3}", "\u{1F3AF}"] {
            #expect(Self.containsEmoji(emoji), "missed \(emoji)")
            #expect(EmojiIdentity.containsEmoji(emoji))
            #expect(!Self.emojiFindings(in: "Text(\"Saved \(emoji)\")", file: "x").isEmpty)
        }
        #expect(!Self.emojiFindings(in: #"Text("Trip \u{2708}\u{FE0F}")"#, file: "x").isEmpty)
        for plain in ["Done", "41% \u{00B7} On track", "Processing\u{2026}", "\u{2212}$20.00", "3\u{2013}30", "1 of 2", "#1", "\u{00A9} MoolaHub"] {
            #expect(!Self.containsEmoji(plain), "flagged \(plain)")
            #expect(!EmojiIdentity.containsEmoji(plain))
        }
        #expect(Self.emojiFindings(in: "Text(\"Done\")\n#Preview { Text(\"\u{1F3AF}\") }", file: "x").isEmpty)
    }

    /// A7.4's predicate: a scalar with `isEmojiPresentation`; a non-ASCII
    /// `isEmoji` scalar followed by U+FE0F; or U+20E3 (keycap).
    static func containsEmoji(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isEmojiPresentation || scalar.value == 0x20E3 { return true }
            if scalar.properties.isEmoji, !scalar.isASCII, index + 1 < scalars.count, scalars[index + 1].value == 0xFE0F {
                return true
            }
        }
        return false
    }

    static func emojiFindings(in text: String, file: String) -> [String] {
        let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var results: [String] = []
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#Preview") || line.range(of: #"^(private |fileprivate )?struct \w+Preview\b"#, options: .regularExpression) != nil {
                break
            }
            if line.hasPrefix("//") { continue }
            let code = rawLine.components(separatedBy: " //").first ?? rawLine
            for match in literal.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                // Decode \u{…} escapes so an escaped emoji is caught too.
                let content = decodingUnicodeEscapes(String(code[range]))
                if containsEmoji(content) {
                    results.append("\(file):\(index + 1): \"\(content)\"")
                }
            }
        }
        return results
    }

    /// `text` with each `\u{…}` escape replaced by the character it names.
    static func decodingUnicodeEscapes(_ text: String) -> String {
        let escape = try! NSRegularExpression(pattern: #"\\u\{([0-9A-Fa-f]{1,8})\}"#)
        var decoded = text
        for found in escape.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)).reversed() {
            guard let whole = Range(found.range, in: decoded),
                  let hexRange = Range(found.range(at: 1), in: decoded),
                  let value = UInt32(decoded[hexRange], radix: 16),
                  let scalar = Unicode.Scalar(value)
            else { continue }
            decoded.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return decoded
    }

    static func findings(in text: String, file: String) -> [String] {
        let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let interpolation = try! NSRegularExpression(pattern: #"\\\((?:[^()]|\([^()]*\))*\)"#)
        var results: [String] = []
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#Preview") || line.range(of: #"^(private |fileprivate )?struct \w+Preview\b"#, options: .regularExpression) != nil {
                break
            }
            if line.hasPrefix("//") || line.hasPrefix("///") { continue }
            let code = rawLine.components(separatedBy: " //").first ?? rawLine
            let range = NSRange(code.startIndex..., in: code)
            for match in literal.matches(in: code, range: range) {
                guard let contentRange = Range(match.range(at: 1), in: code) else { continue }
                let content = String(code[contentRange])
                let copy = interpolation.stringByReplacingMatches(
                    in: content, range: NSRange(content.startIndex..., in: content), withTemplate: " "
                )
                let lower = copy.lowercased()
                var terms = bannedWords.filter { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
                if copy.range(of: #"\bBase\b"#, options: .regularExpression) != nil { terms.append("Base") }
                if copy.range(of: #"\b0x[0-9a-fA-F]"#, options: .regularExpression) != nil { terms.append("0x") }
                if !terms.isEmpty {
                    results.append("\(file):\(index + 1) \(terms.joined(separator: ", ")): \"\(copy)\"")
                }
            }
        }
        return results
    }

    // MARK: Em dash and "!" (DESIGN.md v2 W3)

    /// No em dash (U+2014, typed or as `\u{2014}`) in an app string.
    @Test func noEmDashInAppStrings() throws {
        var findings: [String] = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            findings += Self.emDashFindings(in: text, file: file.path)
        }
        #expect(findings.isEmpty, "em dashes in app strings:\n\(findings.joined(separator: "\n"))")
    }

    @Test func emDashCheckerCatchesTypedAndEscapedDashes() {
        #expect(!Self.emDashFindings(in: "Text(\"Saved \u{2014} on track\")", file: "x").isEmpty)
        #expect(!Self.emDashFindings(in: #"Text("Saved \u{2014} on track")"#, file: "x").isEmpty)
        #expect(Self.emDashFindings(in: "Text(\"3\u{2013}30 days\")", file: "x").isEmpty)
        #expect(Self.emDashFindings(in: #"Text("Move-to-goal")"#, file: "x").isEmpty)
        #expect(Self.emDashFindings(in: "// Saved \u{2014} a comment", file: "x").isEmpty)
        #expect(Self.emDashFindings(in: "Text(\"Done\")\n#Preview { Text(\"a \u{2014} b\") }", file: "x").isEmpty)
        // A multi-line literal's lines are its text.
        #expect(Self.emDashFindings(in: "let note = \"\"\"\n    Saved \u{2014} on track\n    \"\"\"", file: "x") == ["x:2: \"Saved \u{2014} on track\""])
    }

    /// No "!" in an app string's text; interpolations are code and are
    /// removed first.
    @Test func noExclamationInAppStrings() throws {
        var findings: [String] = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            findings += Self.exclamationFindings(in: text, file: file.path)
        }
        #expect(findings.isEmpty, "\"!\" in app strings:\n\(findings.joined(separator: "\n"))")
    }

    @Test func exclamationCheckerReadsOnlyTheCopy() {
        #expect(!Self.exclamationFindings(in: #"Text("Well done!")"#, file: "x").isEmpty)
        #expect(!Self.exclamationFindings(in: #"toast("Saved! \(name)")"#, file: "x").isEmpty)
        #expect(Self.exclamationFindings(in: #"Text("\(items.filter { !$0.isDone }.count) left")"#, file: "x").isEmpty)
        #expect(Self.exclamationFindings(in: #"if !isOn { Text("Off") }"#, file: "x").isEmpty)
        #expect(Self.exclamationFindings(in: #"// Done!"#, file: "x").isEmpty)
        #expect(Self.exclamationFindings(in: "Text(\"Done\")\n#Preview { Text(\"Hi!\") }", file: "x").isEmpty)
        // A multi-line literal's lines are its text, comment-like ones too;
        // the code after its closing delimiter is code again.
        let multiline = "let note = \"\"\"\n    Well done!\n    // Saved!\n    \"\"\"\nif !isOn { Text(\"Off\") }\n// let s = \"\"\"\nif !isOn { Text(\"Off\") }"
        #expect(Self.exclamationFindings(in: multiline, file: "x") == ["x:2: \"Well done!\"", "x:3: \"// Saved!\""])
    }

    static func emDashFindings(in text: String, file: String) -> [String] {
        literalContents(in: text).compactMap { literal -> String? in
            let escaped = literal.content.range(of: #"\\u\{0*2014\}"#, options: .regularExpression) != nil
            guard literal.content.contains("\u{2014}") || escaped else { return nil }
            return "\(file):\(literal.line): \"\(literal.content)\""
        }
    }

    static func exclamationFindings(in text: String, file: String) -> [String] {
        let interpolation = try! NSRegularExpression(pattern: #"\\\((?:[^()]|\([^()]*\))*\)"#)
        return literalContents(in: text).compactMap { literal -> String? in
            let content = literal.content
            let copy = interpolation.stringByReplacingMatches(
                in: content, range: NSRange(content.startIndex..., in: content), withTemplate: " "
            )
            guard copy.contains("!") else { return nil }
            return "\(file):\(literal.line): \"\(copy)\""
        }
    }

    /// Each string literal's text with its 1-based line, under the rules the
    /// other checks use: comment lines and trailing comments are skipped, and
    /// so is everything from a file's first preview to its end. Each line
    /// inside a multi-line literal is text as a whole.
    static func literalContents(in text: String) -> [(line: Int, content: String)] {
        let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var results: [(line: Int, content: String)] = []
        for source in sourceLines(text) {
            let line = source.text.trimmingCharacters(in: .whitespaces)
            if source.isMultilineText {
                results.append((source.number, line))
                continue
            }
            if line.hasPrefix("#Preview") || line.range(of: #"^(private |fileprivate )?struct \w+Preview\b"#, options: .regularExpression) != nil {
                break
            }
            if line.hasPrefix("//") { continue }
            let code = source.text.components(separatedBy: " //").first ?? source.text
            for match in literal.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                results.append((source.number, String(code[range])))
            }
        }
        return results
    }

    /// The lines of `text`, numbered from 1. `isMultilineText` marks the lines
    /// between a multi-line literal's delimiters (`"""` or `#"""` ending a
    /// line, to the line that starts with `"""`): they are the literal's
    /// text, never code, a comment or a directive.
    static func sourceLines(_ text: String) -> [(number: Int, text: String, isMultilineText: Bool)] {
        let delimiter = "\"\"\""
        var inLiteral = false
        var lines: [(number: Int, text: String, isMultilineText: Bool)] = []
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inLiteral {
                // Only the closing delimiter can open a line of the literal with `"""`.
                inLiteral = !line.hasPrefix(delimiter)
                lines.append((index + 1, rawLine, inLiteral))
                continue
            }
            lines.append((index + 1, rawLine, false))
            guard !line.hasPrefix("//") else { continue }
            let code = rawLine.components(separatedBy: " //").first ?? rawLine
            inLiteral = code.trimmingCharacters(in: .whitespaces).hasSuffix(delimiter)
        }
        return lines
    }

    // MARK: Test money (SPEC §1.11 AC-7 check 1, D-37)

    /// Every string literal whose text contains "test money" (any case) lies
    /// in an `#if DEBUG` region, so Release ships none. Previews are scanned
    /// too: a `#Preview` outside `#if DEBUG` compiles into Release.
    @Test func testMoneyLiteralsAreDebugOnly() throws {
        var scanned = 0
        var findings: [String] = []
        for file in Self.sourceFiles() {
            scanned += 1
            let text = try String(contentsOf: file.url, encoding: .utf8)
            findings += Self.testMoneyFindings(in: text, file: file.path)
        }
        #expect(scanned > 40, "found only \(scanned) source files under \(Self.sourcesRoot.path)")
        #expect(findings.isEmpty, "test-money text outside #if DEBUG (it would ship in Release):\n\(findings.joined(separator: "\n"))")
    }

    @Test func testMoneyCheckPassesALiteralUnderIfDebug() {
        let source = """
            #if DEBUG
            Text("Add test money")
            #endif
            PayInBody()
                .padding()
                #if DEBUG
                .sheet(isPresented: $shows) { Text("Test money added") }
                #endif
            """
        #expect(Self.testMoneyFindings(in: source, file: "x").isEmpty)
    }

    @Test func testMoneyCheckFailsALiteralInTheElseBranch() {
        let source = """
            #if DEBUG
            Text("Add money")
            #else
            Text("Add test money")
            #endif
            """
        #expect(Self.testMoneyFindings(in: source, file: "x") == ["x:4: \"Add test money\""])
    }

    @Test func testMoneyCheckFailsALiteralAtTheTopLevel() {
        #expect(Self.testMoneyFindings(in: #"Text("Add test money")"#, file: "x") == ["x:1: \"Add test money\""])
        #expect(Self.testMoneyFindings(in: "#Preview {\n    Text(\"TEST MONEY\")\n}", file: "x") == ["x:2: \"TEST MONEY\""])
        #expect(Self.testMoneyFindings(in: #"// "Add test money" is Debug only"#, file: "x").isEmpty)
    }

    @Test func testMoneyCheckFollowsNesting() {
        let debugOutside = """
            #if DEBUG
            #if targetEnvironment(simulator)
            Text("Test money")
            #else
            Text("Test money")
            #endif
            Text("Test money")
            #endif
            """
        #expect(Self.testMoneyFindings(in: debugOutside, file: "x").isEmpty)
        let debugInside = """
            #if targetEnvironment(simulator)
            #if DEBUG
            Text("Test money")
            #else
            Text("Test money")
            #endif
            Text("Test money")
            #endif
            Text("Test money")
            """
        #expect(Self.testMoneyFindings(in: debugInside, file: "x") == [
            "x:5: \"Test money\"", "x:7: \"Test money\"", "x:9: \"Test money\"",
        ])
    }

    /// A closed `#if DEBUG` block ends the Debug region.
    @Test func testMoneyCheckFailsALiteralAfterADebugBlock() {
        let source = """
            #if DEBUG
            let a = 1
            #endif
            Text("Add test money")
            """
        #expect(Self.testMoneyFindings(in: source, file: "x") == ["x:4: \"Add test money\""])
    }

    @Test func testMoneyCheckFailsALiteralInAnElseifBranch() {
        let source = """
            #if DEBUG
            let a = 1
            #elseif os(iOS)
            Text("Add test money")
            #endif
            """
        #expect(Self.testMoneyFindings(in: source, file: "x") == ["x:4: \"Add test money\""])
    }

    /// Only the plain condition `DEBUG` makes a Debug region.
    @Test func testMoneyCheckCountsOnlyAPlainIfDebug() {
        #expect(Self.testMoneyFindings(in: "#if !DEBUG\nText(\"Add test money\")\n#endif", file: "x") == ["x:2: \"Add test money\""])
        #expect(Self.testMoneyFindings(in: "#if DEBUG && os(iOS)\nText(\"Test money\")\n#endif", file: "x") == ["x:2: \"Test money\""])
        #expect(Self.testMoneyFindings(in: "#if DEBUG // Debug only\nText(\"Test money\")\n#endif", file: "x").isEmpty)
    }

    /// A multi-line literal's lines are its text, under the same regions; a
    /// directive-like line inside one is text, not a directive.
    @Test func testMoneyCheckReadsMultilineLiterals() {
        let topLevel = """
            let note = \"\"\"
                This build uses test money only.
                #if DEBUG
                \"\"\"
            Text("Test money")
            """
        #expect(Self.testMoneyFindings(in: topLevel, file: "x") == [
            "x:2: \"This build uses test money only.\"", "x:5: \"Test money\"",
        ])
        let underDebug = """
            #if DEBUG
            let note = #\"\"\"
                This build uses test money only.
                #endif
                \"\"\"#
            #endif
            """
        #expect(Self.testMoneyFindings(in: underDebug, file: "x").isEmpty)
    }

    /// No-break spaces, typed or escaped, and escaped letters still match.
    @Test func testMoneyCheckFoldsSpacesAndEscapes() {
        for text in ["Add test\u{00A0}money", "Add test\u{202F}money", "Add test  money", #"Add test\u{00A0}money"#, #"Add \u{74}est money"#] {
            #expect(Self.testMoneyFindings(in: "Text(\"\(text)\")", file: "x").count == 1, "missed \(text)")
        }
        #expect(Self.testMoneyFindings(in: #"Text("Add money to test it")"#, file: "x").isEmpty)
    }

    /// Literals containing "test money" outside a Debug region. Regions come
    /// from a stack of `#if` / `#elseif` / `#else` / `#endif` read line by
    /// line (a postfix `#if` in a modifier chain is a line like any other); a
    /// line is in a Debug region when an enclosing `#if DEBUG` is still in its
    /// first branch. Only the plain condition `DEBUG` counts: `#if !DEBUG`
    /// and compound conditions don't. Comments are skipped; previews are
    /// not. A multi-line literal's lines are its text, and the match folds
    /// `\u{…}` escapes and any run of spaces (no-break ones too) first.
    static func testMoneyFindings(in text: String, file: String) -> [String] {
        let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        // One entry per open `#if`: true while it is `#if DEBUG`'s first branch.
        var debugBranches: [Bool] = []
        var results: [String] = []
        for source in sourceLines(text) {
            let line = source.text.trimmingCharacters(in: .whitespaces)
            var contents: [String] = []
            if source.isMultilineText {
                contents = [line]
            } else {
                let directive = (line.components(separatedBy: "//").first ?? line).split(whereSeparator: \.isWhitespace)
                let keyword = directive.first.map { String($0) } ?? ""
                switch keyword {
                case "#if":
                    debugBranches.append(directive.dropFirst().joined(separator: " ") == "DEBUG")
                    continue
                case "#elseif", "#else":
                    if !debugBranches.isEmpty { debugBranches[debugBranches.count - 1] = false }
                    continue
                case "#endif":
                    _ = debugBranches.popLast()
                    continue
                default:
                    break
                }
                if line.hasPrefix("//") { continue }
                let code = source.text.components(separatedBy: " //").first ?? source.text
                contents = literal.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
                    Range(match.range(at: 1), in: code).map { String(code[$0]) }
                }
            }
            if debugBranches.contains(true) { continue }
            for content in contents where mentionsTestMoney(content) {
                results.append("\(file):\(source.number): \"\(content)\"")
            }
        }
        return results
    }

    /// True when `content` says "test money" in any case, with `\u{…}`
    /// escapes decoded and every run of white space (U+00A0 and U+202F
    /// included) read as one space.
    static func mentionsTestMoney(_ content: String) -> Bool {
        decodingUnicodeEscapes(content)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
            .contains("test money")
    }
}
