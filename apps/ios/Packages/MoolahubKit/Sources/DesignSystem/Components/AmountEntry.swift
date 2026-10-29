import Domain
import SwiftUI

/// A preset chip under the amount display ("$50", "All", "Next step $12.40").
public struct AmountPreset: Hashable, Sendable, Identifiable {
    public let label: String
    public let money: Money
    /// The plan's next step ("Next step {amount}"): alone on its own centred
    /// row 8 pt above the fixed presets (A8.12).
    public let isSuggested: Bool

    public var id: String { label }

    public init(label: String, money: Money, isSuggested: Bool = false) {
        self.label = label
        self.money = money
        self.isSuggested = isSuggested
    }

    /// "$50" style chip (`wholeIfRound`).
    public static func amount(_ money: Money) -> AmountPreset {
        AmountPreset(label: money.formatted(.wholeIfRound), money: money)
    }

    var isAll: Bool { label == "All" }

    var accessibilityLabel: String {
        if isSuggested { return "Next step, \(money.accessibilityText())" }
        if isAll { return "All, \(money.accessibilityText())" }
        return money.accessibilityText()
    }
}

/// USD amount entry with a custom keypad (DESIGN.md v2 A8.12). The buffer
/// rules live in `Domain.AmountEntryBuffer`; the feature owns validation,
/// passes the message to show and disables its main button (an amount step
/// has no reason line: the empty "$0" or the validation message is the reason).
///
/// Display (`displayEntry`, centred; empty "$0" in `textTertiary`); the
/// context line 8 pt below (`subheadline` `textSecondary`); the RESERVED
/// validation slot, two `footnote` lines tall, 4 pt below the context line (8
/// below the display without one), so presets and keypad never move while
/// someone types; presets 20 pt below (36 pt `fill` capsules in 44 pt rows,
/// the one equal to the buffer selected in ink; the suggested one on its own
/// row; over-the-maximum ones and "All" at a $0.00 maximum disabled); the
/// keypad 24 pt below (56 pt rows, no key backgrounds, a 56 pt `fillPressed`
/// circle while pressed). `.selection` on a preset, `.warning` on a refused key.
public struct AmountEntry: View {
    @Binding var buffer: AmountEntryBuffer
    let context: String?
    let presets: [AmountPreset]
    let maximum: Money?
    let validationMessage: String?
    let isEnabled: Bool
    let contextLoadingLabel: String?

    @State private var rejectedKeyCount = 0
    @State private var presetTapCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var validationSlotHeight: CGFloat = 32.6

    /// - Parameters:
    ///   - context: "Available $1,240.50", "In this goal $300.00", …
    ///   - maximum: presets above it are disabled.
    ///   - validationMessage: shown in `redText` in the reserved slot (W10.5).
    ///   - isEnabled: false while the maximum is still loading (keys `textTertiary`).
    ///   - contextLoadingLabel: while the context's figure loads (B3.19), the
    ///     context line is a 123 × 9.9 skeleton that VoiceOver reads as this
    ///     label ("Loading your balance…"); `context` is ignored meanwhile.
    public init(
        buffer: Binding<AmountEntryBuffer>,
        context: String?,
        presets: [AmountPreset] = [],
        maximum: Money? = nil,
        validationMessage: String? = nil,
        isEnabled: Bool = true,
        contextLoadingLabel: String? = nil
    ) {
        self._buffer = buffer
        self.context = context
        self.presets = presets
        self.maximum = maximum
        self.validationMessage = validationMessage
        self.isEnabled = isEnabled
        self.contextLoadingLabel = contextLoadingLabel
    }

    public var body: some View {
        VStack(spacing: 0) {
            display
            if let contextLoadingLabel {
                // The line's own height, with the skeleton centred on it (A5.7).
                Text(verbatim: " ")
                    .textStyle(.subheadline)
                    .frame(maxWidth: .infinity)
                    .hidden()
                    .overlay {
                        LoadingPlaceholder(label: contextLoadingLabel) {
                            SkeletonBlock(width: 123, height: TypeToken.subheadline.capHeight, relativeTo: TypeToken.subheadline.relativeTo)
                        }
                        .accessibilityAddTraits(.isStaticText)
                    }
                    .padding(.top, Spacing.space2)
            } else if let context {
                Text(context)
                    .textStyle(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
            validationSlot
                .padding(.top, context == nil && contextLoadingLabel == nil ? Spacing.space2 : Spacing.space1)
            if !presets.isEmpty {
                presetRows
                    .padding(.top, Spacing.space5)
            }
            keypad
                .padding(.top, Spacing.space6)
        }
        .disabled(!isEnabled)
        .sensoryFeedback(.warning, trigger: rejectedKeyCount)
        .sensoryFeedback(.selection, trigger: presetTapCount)
    }

    private var display: some View {
        Text(buffer.displayText)
            .textStyle(.displayEntry)
            .foregroundStyle(buffer.isEmpty ? Palette.textTertiary : Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Amount")
            .accessibilityValue(buffer.money.map { $0.accessibilityText() } ?? "empty")
    }

    private var validationSlot: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(height: validationSlotHeight)
            if let validationMessage {
                Text(validationMessage)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.redText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: validationMessage)
    }

    /// The suggested preset alone on its own row, 8 pt above the fixed presets,
    /// which wrap onto centred rows (`ChipFlowLayout`).
    private var presetRows: some View {
        VStack(spacing: Spacing.space2) {
            ForEach(presets.filter(\.isSuggested)) { preset in
                chip(preset)
            }
            ChipFlowLayout(spacing: Spacing.space2) {
                ForEach(presets.filter { !$0.isSuggested }) { preset in
                    chip(preset)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(_ preset: AmountPreset) -> some View {
        let tooLarge = maximum.map { preset.money > $0 } ?? false
        let emptyAll = preset.isAll && (maximum?.isZero ?? preset.money.isZero)
        let isSelected = buffer.money == preset.money
        return Button {
            buffer.set(preset.money)
            presetTapCount += 1
        } label: {
            // Digits never truncate (A2.5 rule 1): at accessibility sizes a
            // chip that doesn't fit wraps ("Next step" / "$381.82") on a
            // rounded rectangle instead of a capsule.
            Text(preset.label)
                .textStyle(.subheadlineEmphasis)
                .monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                .padding(.horizontal, 14)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? Spacing.space2 : 0)
                .frame(minHeight: Size.smallButtonHeight)
        }
        .buttonStyle(PresetChipStyle(isSelected: isSelected))
        .frame(minHeight: Size.minimumTapTarget)
        .contentShape(Rectangle())
        .disabled(tooLarge || emptyAll)
        .accessibilityLabel(preset.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var keypad: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                key(.digit(1), "1", spoken: "1")
                key(.digit(2), "2", spoken: "2")
                key(.digit(3), "3", spoken: "3")
            }
            GridRow {
                key(.digit(4), "4", spoken: "4")
                key(.digit(5), "5", spoken: "5")
                key(.digit(6), "6", spoken: "6")
            }
            GridRow {
                key(.digit(7), "7", spoken: "7")
                key(.digit(8), "8", spoken: "8")
                key(.digit(9), "9", spoken: "9")
            }
            GridRow {
                key(.decimalPoint, ".", spoken: "decimal point")
                key(.digit(0), "0", spoken: "0")
                deleteKey
            }
        }
    }

    private func key(_ key: AmountEntryBuffer.Key, _ label: String, spoken: String) -> some View {
        Button {
            if !buffer.press(key) { rejectedKeyCount += 1 }
        } label: {
            Text(verbatim: label)
                .textStyle(.keypad)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeypadKeyStyle())
        .accessibilityLabel(spoken)
        .accessibilityShowsLargeContentViewer()
    }

    private var deleteKey: some View {
        Button {
            if !buffer.press(.delete) { rejectedKeyCount += 1 }
        } label: {
            // 22 pt Regular, scaling with the keypad digits and capped with them (A7.1, A8.12).
            DeleteKeyGlyph()
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeypadKeyStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in buffer.clear() })
        .accessibilityLabel("delete")
        .accessibilityAction(named: "Clear") { buffer.clear() }
        .accessibilityShowsLargeContentViewer()
    }
}

/// The keypad's `delete.left`: 22 pt Regular on the keypad's `.title` curve.
/// The caller caps it at AX1 outside this view, which owns the size.
private struct DeleteKeyGlyph: View {
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 22

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: size, weight: .regular))
    }
}

/// A preset chip: `fill` → `fillPressed` (selected: `ctaBackground` →
/// `ctaPressed`), no scale; disabled `textTertiary`; Increase Contrast adds a
/// 1 pt `cardBorder` (A5.2, A8.12).
struct PresetChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        PresetChipBody(configuration: configuration, isSelected: isSelected)
    }

    private struct PresetChipBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let fill: Color = isSelected
                ? (pressed ? Palette.ctaPressed : Palette.ctaBackground)
                : (pressed ? Palette.fillPressed : Palette.fill)
            configuration.label
                .foregroundStyle(!isEnabled ? Palette.textTertiary : (isSelected ? Palette.ctaForeground : Palette.textPrimary))
                .background {
                    if dynamicTypeSize.isAccessibilitySize {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill)
                    } else {
                        Capsule().fill(fill)
                    }
                }
                .overlay {
                    if contrast == .increased && !isSelected {
                        if dynamicTypeSize.isAccessibilitySize {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.cardBorder, lineWidth: Size.hairline)
                        } else {
                            Capsule().strokeBorder(Palette.cardBorder, lineWidth: Size.hairline)
                        }
                    }
                }
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
                .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: isSelected)
        }
    }
}

/// A keypad key: digits in `keypad` `textPrimary` (`textTertiary` disabled), no
/// key background; a 56 pt `fillPressed` circle behind the digit at
/// touch-down, fading with `Motion.exit` on release (A5.2). No haptic on digits.
struct KeypadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration)
    }

    private struct KeyBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                .background {
                    Circle()
                        .fill(Palette.fillPressed)
                        .frame(width: 56, height: 56)
                        .opacity(pressed ? 1 : 0)
                        .animation(pressed ? nil : (Motion.animation(Motion.exit, reduceMotion: reduceMotion)), value: pressed)
                }
        }
    }
}

/// Lays chips out left to right, wrapping onto new lines, with `spacing` both
/// ways (A8.12). A chip wider than the whole width gets its own line. Each
/// line is centred (the amount presets) or, with `alignment: .leading`, starts
/// at the leading edge (chips under a leading-aligned field, such as Create
/// group's invited emails).
public struct ChipFlowLayout: Layout {
    public var spacing: CGFloat
    public var alignment: HorizontalAlignment

    public init(spacing: CGFloat = Spacing.space2, alignment: HorizontalAlignment = .center) {
        self.spacing = spacing
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for line in lines {
            let slack = max(0, bounds.width - line.width)
            var x = bounds.minX + (alignment == .leading ? 0 : alignment == .trailing ? slack : slack / 2)
            for item in line.items {
                let size = item.size
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && needed > width {
                lines.append(current)
                current = Line()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty {
            lines.append(current)
        }
        return lines
    }
}

/// An item the person added, with its remove button (A8.12, ruling 33;
/// Create group's invited emails): a 36 pt `fill` capsule (44 pt hit height),
/// the text (`subheadlineEmphasis`, one line, middle truncation), a trailing
/// `xmark.circle.fill` 16 pt `textSecondary` in a 44 × 44 hit area labelled
/// "Remove {text}". Lay chips out in `ChipFlowLayout`. Increase Contrast adds
/// a 1 pt `cardBorder`.
public struct RemovableChip: View {
    let text: String
    let onRemove: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .footnote) private var symbolSize: CGFloat = 16

    public init(text: String, onRemove: @escaping () -> Void) {
        self.text = text
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: text)
                .textStyle(.subheadlineEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 14)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: symbolSize))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Size.minimumTapTarget, height: Size.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MoolaButtonStyle(kind: .plain, fullWidth: false))
            .accessibilityLabel("Remove \(text)")
        }
        .frame(minHeight: Size.smallButtonHeight)
        .background(Capsule().fill(Palette.fill))
        .overlay {
            if contrast == .increased { Capsule().strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
        }
        .frame(minHeight: Size.minimumTapTarget)
    }
}

private struct AmountEntryPreview: View {
    @State private var buffer = AmountEntryBuffer(text: "25")

    var body: some View {
        AmountEntry(
            buffer: $buffer,
            context: "Available $1,520.00",
            presets: [
                AmountPreset(label: "Next step $17.85", money: Money(cents: 1_785), isSuggested: true),
                .amount(Money(cents: 1_000)), .amount(Money(cents: 2_500)), .amount(Money(cents: 5_000)),
                AmountPreset(label: "All", money: Money(cents: 152_000)),
            ],
            maximum: Money(cents: 152_000),
            validationMessage: nil
        )
        .padding(20)
        .moolaCanvas()
    }
}

#Preview("Amount entry") {
    AmountEntryPreview()
}
