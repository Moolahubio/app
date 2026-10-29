import APIClient
import CoreText
import DesignSystem
import Foundation
import Persistence
import Security
import SwiftUI
import Testing
import UIKit

/// App-hosted checks: things only the real app bundle can prove (Info.plist
/// policy, Keychain access, the system fonts the type scale uses).
@MainActor
@Suite("App bundle")
struct AppBundleTests {
    @Test func infoPlistBasics() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["CFBundleDisplayName"] as? String == "MoolaHub")
        #expect(info["NSFaceIDUsageDescription"] as? String == "MoolaHub uses Face ID to unlock the app and confirm money moves.")
        // No bundled fonts: SF Pro and SF Pro Rounded are the system's (DESIGN.md v2 A2.1).
        #expect(info["UIAppFonts"] == nil)
        #expect(Bundle.main.bundleIdentifier == "io.moolahub.app.dev")
    }

    @Test func debugBuildAllowsOnlyLocalNetworkingOverHTTP() throws {
        #if DEBUG
        let info = Bundle.main.infoDictionary ?? [:]
        let ats = try #require(info["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats.keys.sorted() == ["NSAllowsLocalNetworking"])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(info["NSLocalNetworkUsageDescription"] as? String != nil)
        // The dev Mac's name reaches ServerEnvironment through this key (an
        // empty string without Config/Local.xcconfig).
        #expect(info[ServerEnvironment.devMacHostInfoKey] is String)
        #endif
    }

    /// Reads the two source plists and proves Release has no ATS exception, no
    /// local-network permission and no dev Mac name, and is otherwise identical
    /// to Debug.
    @Test func releasePlistHasNoTransportExceptions() throws {
        let config = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config")
        let release = try plist(config.appendingPathComponent("Info.plist"))
        var debug = try plist(config.appendingPathComponent("Info-Debug.plist"))
        #expect(release["NSAppTransportSecurity"] == nil)
        #expect(release["NSLocalNetworkUsageDescription"] == nil)
        #expect(release[ServerEnvironment.devMacHostInfoKey] == nil)
        #expect(debug[ServerEnvironment.devMacHostInfoKey] as? String == "$(DEV_MAC_HOST)")
        debug.removeValue(forKey: "NSAppTransportSecurity")
        debug.removeValue(forKey: "NSLocalNetworkUsageDescription")
        debug.removeValue(forKey: ServerEnvironment.devMacHostInfoKey)
        #expect(NSDictionary(dictionary: debug).isEqual(to: release))
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Money figures are SF Pro Rounded with tabular digits (DESIGN.md v2 A2.1,
    /// A2.3, U7): "$1,111.11" and "$8,888.88" measure the same width in
    /// `displayHero` (40 Bold) and `amountRow` (16 Medium), rendered through
    /// the tokens' own SwiftUI fonts.
    @Test(arguments: [TypeToken.displayHero, TypeToken.amountRow])
    func moneyDigitsAreTabular(token: TypeToken) throws {
        #expect(token.design == .rounded)
        #expect(token.isFigure)
        let ones = try renderedWidth("$1,111.11", token: token)
        let eights = try renderedWidth("$8,888.88", token: token)
        #expect(ones > 0)
        #expect(abs(ones - eights) < 0.01, "\(token): $1,111.11 is \(ones) pt, $8,888.88 is \(eights) pt")
    }

    /// The same check straight on the system font: SF Pro Rounded's
    /// proportional ones are narrower, so the tabular feature is what makes them equal.
    @Test func roundedSystemFontHasProportionalAndTabularDigits() throws {
        let base = UIFont.systemFont(ofSize: 40, weight: .bold)
        let rounded = try #require(base.fontDescriptor.withDesign(.rounded))
        let proportional = UIFont(descriptor: rounded, size: 40)
        let tabular = UIFont(descriptor: rounded.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
            ]],
        ]), size: 40)
        func width(_ text: String, _ font: UIFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        #expect(abs(width("$1,111.11", tabular) - width("$8,888.88", tabular)) < 0.01)
        #expect(width("$1,111.11", proportional) < width("$8,888.88", proportional))
    }

    private func renderedWidth(_ text: String, token: TypeToken) throws -> CGFloat {
        let renderer = ImageRenderer(content: Text(verbatim: text).textStyle(token).fixedSize())
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        return image.size.width
    }
}

/// Keychain round trip in a real app process (package tests can't reach the
/// Keychain on the simulator).
@Suite("Keychain (app-hosted)", .serialized)
struct KeychainHostedTests {
    @Test func tokenRoundTripWithDeviceOnlyAccessibility() throws {
        let store = KeychainTokenStore(service: "io.moolahub.app.tests.\(UUID().uuidString)")
        defer { try? store.deleteToken() }
        #expect(try store.readToken() == nil)
        try store.saveToken("first-token")
        #expect(try store.readToken() == "first-token")
        try store.saveToken("second-token")
        #expect(try store.readToken() == "second-token")
        #expect(store.storedAccessibility() == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        try store.deleteToken()
        #expect(try store.readToken() == nil)
        try store.deleteToken()
    }
}

/// DesignSystem's identity colours for one list (DESIGN.md A1.9; the lead's
/// ruling on F1P-1) and the selection pill's step (A8.21; F1P-2). Here because
/// DesignSystem has no package test target.
@MainActor
@Suite("Identity tints and the selection pill")
struct IdentityTintTests {
    @Test func oneKeyKeepsItsHashedColour() {
        #expect(IdentityTint.for(key: "ama") == .berry)
        #expect(IdentityTint.for(key: "kofi") == .berry)
        #expect(IdentityTint.for(key: "Esi") == .cobalt)
        #expect(IdentityTint.distinct(forKeys: ["kofi"]) == ["kofi": .berry])
        #expect(IdentityTint.distinct(forKeys: []).isEmpty)
    }

    /// The seeded groups: the hash alone draws Family susu berry, cobalt,
    /// cobalt, berry and Holiday pot cobalt, berry, cobalt.
    @Test func seededGroupsGetOneColourEach() {
        #expect(IdentityTint.distinct(forKeys: ["kofi", "esi", "yaw", "ama"])
            == ["ama": .berry, "esi": .cobalt, "kofi": .graphite, "yaw": .ocean])
        #expect(IdentityTint.distinct(forKeys: ["ama", "abena", "yaw"])
            == ["abena": .cobalt, "ama": .berry, "yaw": .ocean])
    }

    @Test func keysThatDoNotCollideKeepTheirOwnColour() {
        let keys = ["esi", "wanjiru", "ama", "thabo"]
        let tints = IdentityTint.distinct(forKeys: keys)
        for key in keys {
            #expect(tints[key] == IdentityTint.for(key: key), "\(key)")
        }
        #expect(Set(tints.values).count == 4)
    }

    @Test func keysMatchCaseInsensitively() {
        let tints = IdentityTint.distinct(forKeys: ["Ama", "ama", "kofi"])
        #expect(tints.count == 3)
        #expect(tints["Ama"] == tints["ama"])
        #expect(tints["ama"] != tints["kofi"])
    }

    /// Every subset of nine names: no tint repeats while another is unused,
    /// the uses differ by one at most past four people, every key has an
    /// entry, and the order of the keys never changes the result.
    @Test func noRepeatWhileATintIsFreeAndTheOrderNeverMatters() {
        let pool = ["ama", "kofi", "esi", "yaw", "abena", "kwame", "wanjiru", "thabo", "njeri"]
        for mask in 1..<(1 << pool.count) {
            let keys = pool.indices.filter { mask & (1 << $0) != 0 }.map { pool[$0] }
            let tints = IdentityTint.distinct(forKeys: keys)
            let uses = IdentityTint.allCases.map { tint in tints.values.filter { $0 == tint }.count }
            #expect(tints.count == keys.count)
            #expect((uses.max() ?? 0) - (uses.min() ?? 0) <= 1, "\(keys)")
            #expect(IdentityTint.distinct(forKeys: keys.reversed()) == tints, "\(keys)")
        }
    }

    /// F1P-2: the light pill is at least a 1.10 : 1 step on `canvas`; dark
    /// and sheets keep `surface`'s step; Increase Contrast's fill steps are no
    /// smaller than before (the pill also draws its 1 pt `cardBorder` there).
    @Test func selectionPillStepIsAtLeastTheRuledOne() {
        func traits(_ style: UIUserInterfaceStyle, elevated: Bool = false, highContrast: Bool = false) -> UITraitCollection {
            UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.userInterfaceLevel = elevated ? .elevated : .base
                traits.accessibilityContrast = highContrast ? .high : .normal
            }
        }
        func luminance(_ color: UIColor, _ traits: UITraitCollection) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ channel: CGFloat) -> Double {
                let value = Double(channel)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func step(_ fill: UIColor, _ traits: UITraitCollection) -> Double {
            let fill = luminance(fill, traits), ground = luminance(PaletteUIColor.canvas, traits)
            return (max(fill, ground) + 0.05) / (min(fill, ground) + 0.05)
        }
        #expect(step(PaletteUIColor.selectionPill, traits(.light)) >= 1.10)
        #expect(step(PaletteUIColor.selectionPill, traits(.light, highContrast: true)) >= 1.10)
        for (style, elevated) in [(UIUserInterfaceStyle.dark, false), (.dark, true)] {
            for highContrast in [false, true] {
                let mode = traits(style, elevated: elevated, highContrast: highContrast)
                #expect(step(PaletteUIColor.selectionPill, mode) >= step(PaletteUIColor.surface, mode) - 0.000_1)
            }
        }
    }
}
