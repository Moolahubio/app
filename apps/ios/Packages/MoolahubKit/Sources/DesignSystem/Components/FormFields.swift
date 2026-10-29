import SwiftUI
import UIKit

/// Splits "Legal name · private" into the label and its suffix (A8.26): the
/// suffix (" · optional", " · private", " · public") is drawn in `textSecondary`.
/// Drawn with a no-break space before the dot, so a label that wraps at
/// accessibility sizes ends a line on the dot ("Legal name ·" / "private"),
/// never starts one with it. The field's accessibility label stays the plain
/// string (tests type into `textFields["Legal name · private"]`).
private func fieldLabelText(_ label: String) -> Text {
    let separator = " \u{00B7} "
    guard let range = label.range(of: separator) else {
        return Text(label).foregroundStyle(Palette.textPrimary)
    }
    let head = String(label[..<range.lowerBound])
    let suffix = String(label[range.lowerBound...]).keepingMiddleDotsAtLineEnds
    return Text("\(Text(head).foregroundStyle(Palette.textPrimary))\(Text(suffix).foregroundStyle(Palette.textSecondary))")
        .accessibilityLabel(label)
}

/// A labelled text field (DESIGN.md v2 A8.26, ruling 54). Label above
/// (`body` `textPrimary`, 12 pt above the field); the field 52 pt min, `fill`,
/// radius 10, **no border at rest** (1 pt `controlBorder` only with Increase
/// Contrast); focused 1.5 pt `textPrimary` (2 pt with Increase Contrast);
/// error 1.5 pt `redText` and the message (`footnote` `redText`) 8 pt below;
/// hint (`footnote` `textSecondary`) 8 pt below; disabled text `textTertiary`.
/// Text `body` `textPrimary`, placeholder `textTertiary` ("e.g. …"). The field's
/// accessibility label is the full label string (tests type into
/// `textFields["Goal name"]`, `secureTextFields["Password"]`).
public struct MoolaTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String?
    let error: String?
    let isInvalid: Bool
    let isSecure: Bool
    let leadingAdornment: String?
    let trailing: AnyView?
    let contentType: UITextContentType?
    let keyboard: UIKeyboardType
    let autocapitalization: TextInputAutocapitalization
    let autocorrection: Bool

    @FocusState private var isFocused: Bool
    @State private var isRevealed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .callout) private var eyeSize: CGFloat = 18

    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        hint: String? = nil,
        error: String? = nil,
        isInvalid: Bool = false,
        isSecure: Bool = false,
        leadingAdornment: String? = nil,
        contentType: UITextContentType? = nil,
        keyboard: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .sentences,
        autocorrection: Bool = true,
        trailing: AnyView? = nil
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.hint = hint
        self.error = error
        self.isInvalid = isInvalid
        self.isSecure = isSecure
        self.leadingAdornment = leadingAdornment
        self.contentType = contentType
        self.keyboard = keyboard
        self.autocapitalization = autocapitalization
        self.autocorrection = autocorrection
        self.trailing = trailing
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            fieldLabelText(label)
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.space2) {
                if let leadingAdornment {
                    Text(leadingAdornment)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                }
                field
                    .textStyle(.body)
                    .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                    .textContentType(contentType)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled(!autocorrection)
                    .focused($isFocused)
                    .accessibilityLabel(label)
                    .accessibilityHint(error ?? hint ?? "")
                    // At the default size the 52 pt minimum decides the height; at
                    // accessibility sizes the text outgrows it and this keeps the
                    // glyphs off the edge (A8.26: about 76 pt at AX5).
                    .padding(.vertical, Spacing.space2)
                if isSecure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: eyeSize, weight: .regular))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(minWidth: Size.minimumTapTarget, minHeight: Size.minimumTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
                }
                if let trailing {
                    trailing
                }
            }
            .padding(.leading, Spacing.space4)
            .padding(.trailing, isSecure ? Spacing.space1 : Spacing.space4)
            .frame(minHeight: Size.textFieldHeight)
            .background(Palette.fill, in: shape)
            .overlay {
                if let border {
                    shape.strokeBorder(border.color, lineWidth: border.width)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .padding(.top, Spacing.labelToField)
            if let error {
                Text(error)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            } else if let hint {
                Text(hint)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let prompt = Text(placeholder).foregroundStyle(Palette.textTertiary)
        if isSecure && !isRevealed {
            SecureField("", text: $text, prompt: prompt)
        } else {
            TextField("", text: $text, prompt: prompt)
        }
    }

    /// Ruling 54: borderless at rest; Increase Contrast adds 1 pt `controlBorder`.
    private var border: (color: Color, width: CGFloat)? {
        let increased = contrast == .increased
        if !isEnabled { return increased ? (Palette.divider, 1) : nil }
        if error != nil || isInvalid { return (Palette.redText, increased ? Size.focusBorderIncreasedContrast : Size.focusBorder) }
        if isFocused { return (Palette.textPrimary, increased ? Size.focusBorderIncreasedContrast : Size.focusBorder) }
        return increased ? (Palette.controlBorder, 1) : nil
    }
}

/// A field-styled button that opens a value step or a date popover (A8.26,
/// ruling 17, ruling 54): the label above as for fields; the control 52 pt
/// min, `fill`, borderless at rest (1 pt `controlBorder` with Increase
/// Contrast), radius 10; the value in `body` `textPrimary` with tabular digits
/// or the placeholder in `textTertiary`; a trailing `chevron.forward` (14 pt
/// Semibold `chevron`) when it pushes a step, or `calendar` (18 pt Regular
/// `textSecondary`) when it opens the graphical `DatePicker`. Pressed
/// `fillPressed` at once, back with `Motion.release`, no scale. VoiceOver: one
/// button, label = the field's label, value = `accessibilityValue` when
/// passed, else the shown value, else "empty". Sign up's date of birth passes
/// `date?.formatted(date: .long, time: .omitted) ?? "Choose a date"`.
public struct PickerField: View {
    let label: String
    let value: String?
    let placeholder: String
    let accessibilityValue: String?
    let trailingSymbol: String
    let error: String?
    let identifier: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .callout) private var chevronSize: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var calendarSize: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var calendarSlot: CGFloat = 24

    /// - Parameters:
    ///   - trailingSymbol: "chevron.forward" (pushes a step) or "calendar" (date popover).
    ///   - identifier: applied to the button (tests tap `buttons["savings.create.target"]`).
    public init(
        label: String,
        value: String?,
        placeholder: String,
        accessibilityValue: String? = nil,
        trailingSymbol: String = "chevron.forward",
        error: String? = nil,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.accessibilityValue = accessibilityValue
        self.trailingSymbol = trailingSymbol
        self.error = error
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let isCalendar = trailingSymbol == "calendar"
        VStack(alignment: .leading, spacing: 0) {
            fieldLabelText(label)
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Button(action: action) {
                HStack(spacing: Spacing.space2) {
                    Text(value ?? placeholder)
                        .textStyle(.body)
                        .monospacedDigit()
                        .foregroundStyle(value == nil || !isEnabled ? Palette.textTertiary : Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: trailingSymbol)
                        .font(.system(size: isCalendar ? calendarSize : chevronSize, weight: isCalendar ? .regular : .semibold))
                        .foregroundStyle(isCalendar ? Palette.textSecondary : Palette.chevron)
                        .frame(width: isCalendar ? calendarSlot : nil)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.space4)
                .padding(.vertical, Spacing.space2)
                .frame(minHeight: Size.textFieldHeight)
                .contentShape(shape)
            }
            .buttonStyle(PickerFieldStyle(shape: shape, enabled: isEnabled, hasError: error != nil))
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityValue ?? value ?? "empty")
            .modifier(OptionalIdentifier(identifier: identifier))
            .padding(.top, Spacing.labelToField)
            if let error {
                Text(error)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
        }
    }
}

/// The field-styled control's press and edge (A8.26): `fill`, pressed
/// `fillPressed` at once and back with `Motion.release`, no scale; an error's
/// 1.5 pt `redText` border; 1 pt `controlBorder` (`divider` when disabled)
/// with Increase Contrast. Shared by `PickerField` and `PickerMenuField`.
private struct PickerFieldStyle: ButtonStyle {
    let shape: RoundedRectangle
    let enabled: Bool
    let hasError: Bool

    func makeBody(configuration: Configuration) -> some View {
        PickerFieldBody(configuration: configuration, shape: shape, enabled: enabled, hasError: hasError)
    }
}

private struct PickerFieldBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: RoundedRectangle
    let enabled: Bool
    let hasError: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let pressed = configuration.isPressed
        let increased = contrast == .increased
        configuration.label
            .background(pressed ? Palette.fillPressed : Palette.fill, in: shape)
            .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
            .overlay {
                if hasError {
                    shape.strokeBorder(Palette.redText, lineWidth: increased ? Size.focusBorderIncreasedContrast : Size.focusBorder)
                } else if increased {
                    shape.strokeBorder(enabled ? Palette.controlBorder : Palette.divider, lineWidth: Size.hairline)
                }
            }
    }
}

/// `PickerField`'s menu variant (A8.26 addition, account.md §13.1): the same
/// label and field look, with a trailing `chevron.up.chevron.down` (14 pt
/// Semibold `textSecondary` in a 24 pt slot, 16 pt from the edge) and a system
/// pop-up menu instead of a pushed step. The menu holds an inline `Picker`
/// over `selection`, so the system draws the current choice's checkmark.
/// `trailingOptions`, when passed, are drawn after the system's menu
/// separator as a second inline `Picker` on the same `selection` (one
/// checkmark in the whole menu): "Prefer not to say" after the server's seven
/// (B1.14). `Section`s or a `Divider` inside `options` draw no separator in an
/// inline picker on iOS 26.5. `value` is the chosen option's name (nil shows
/// the placeholder in `textTertiary`). No error state (its only use is
/// optional). At accessibility sizes the value wraps and the symbol stays
/// trailing on the first line. VoiceOver: one button; label the field's
/// label, value the chosen name or the placeholder, the caller's hint
/// ("Shows choices.").
public struct PickerMenuField<Selection: Hashable, Options: View, Trailing: View>: View {
    let label: String
    let value: String?
    let placeholder: String
    let hint: String?
    @Binding var selection: Selection
    let identifier: String?
    let options: Options
    let trailingOptions: Trailing?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var symbolSlot: CGFloat = 24

    /// - Parameters:
    ///   - options: the menu's choices, each tagged with its `Selection` value.
    ///   - identifier: applied to the control (`auth.signUp.referralSource`).
    ///   - trailingOptions: choices set apart after a separator, tagged the
    ///     same way ("Prefer not to say").
    public init(
        label: String,
        value: String?,
        placeholder: String,
        hint: String? = nil,
        selection: Binding<Selection>,
        identifier: String? = nil,
        @ViewBuilder options: () -> Options,
        @ViewBuilder trailingOptions: () -> Trailing
    ) {
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.hint = hint
        self._selection = selection
        self.identifier = identifier
        self.options = options()
        self.trailingOptions = trailingOptions()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            fieldLabelText(label)
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Menu {
                Picker(selection: $selection) {
                    options
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                if let trailingOptions {
                    Divider()
                    Picker(selection: $selection) {
                        trailingOptions
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .firstTextBaseline : .center, spacing: Spacing.space2) {
                    Text(value ?? placeholder)
                        .textStyle(.body)
                        .foregroundStyle(value == nil || !isEnabled ? Palette.textTertiary : Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: symbolSize, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: symbolSlot)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.space4)
                .padding(.vertical, Spacing.space2)
                .frame(minHeight: Size.textFieldHeight)
                .contentShape(shape)
            }
            .menuStyle(.button)
            .buttonStyle(PickerFieldStyle(shape: shape, enabled: isEnabled, hasError: false))
            .accessibilityLabel(label)
            .accessibilityValue(value ?? placeholder)
            .accessibilityHint(hint ?? "")
            .modifier(OptionalIdentifier(identifier: identifier))
            .padding(.top, Spacing.labelToField)
        }
    }
}

extension PickerMenuField where Trailing == EmptyView {
    /// Every choice in one group: the form every caller had before
    /// `trailingOptions` (D-39).
    public init(
        label: String,
        value: String?,
        placeholder: String,
        hint: String? = nil,
        selection: Binding<Selection>,
        identifier: String? = nil,
        @ViewBuilder options: () -> Options
    ) {
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.hint = hint
        self._selection = selection
        self.identifier = identifier
        self.options = options()
        self.trailingOptions = nil
    }
}

/// A label and a read-only value styled apart from editable fields (A8.26,
/// ruling 36): the label above as for fields; the value in a 52 pt `surface`
/// box, no border, radius 10, `body` `textSecondary`; an optional trailing
/// accessory (`StatusPill("Verified", tone: .jade)`). Increase Contrast adds a
/// 1 pt `cardBorder`. One combined accessibility element.
public struct ReadOnlyField<Accessory: View>: View {
    let label: String
    let value: String
    let accessory: Accessory

    @Environment(\.colorSchemeContrast) private var contrast

    public init(label: String, value: String, @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        self.value = value
        self.accessory = accessory()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            fieldLabelText(label)
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.space2) {
                    valueText.frame(maxWidth: .infinity, alignment: .leading)
                    accessory
                }
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    valueText
                    accessory
                }
            }
            .padding(.horizontal, Spacing.space4)
            .padding(.vertical, Spacing.space3)
            .frame(maxWidth: .infinity, minHeight: Size.textFieldHeight, alignment: .leading)
            .background(Palette.surface, in: shape)
            .overlay {
                if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
            }
            .padding(.top, Spacing.labelToField)
        }
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        Text(value)
            .textStyle(.body)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension ReadOnlyField where Accessory == EmptyView {
    public init(label: String, value: String) {
        self.init(label: label, value: value) { EmptyView() }
    }
}

/// The 6-digit code field (A8.26, ruling 22): one field, 60 pt min, the `code`
/// style (SF Pro Rounded 28 Medium, tabular, tracking +8) centred; placeholder
/// "6-digit code" at the code size with tracking 0 in `textTertiary`; no
/// visible label (the screen's title asks the question): the accessibility
/// label names it ("Verification code", "Authenticator code"). Number pad,
/// one-time-code autofill, digits only, at most 6. Borders as `MoolaTextField`.
/// `identifier` is optional: a field that tests find by its label (Two-factor's
/// "Authenticator code", B1.21 adds no identifier) passes none, and then its
/// error line has none either.
public struct CodeField: View {
    @Binding var code: String
    let accessibilityLabel: String
    let identifier: String?
    let error: String?
    let isFocused: FocusState<Bool>.Binding

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    public init(code: Binding<String>, accessibilityLabel: String, identifier: String? = nil, error: String?, isFocused: FocusState<Bool>.Binding) {
        self._code = code
        self.accessibilityLabel = accessibilityLabel
        self.identifier = identifier
        self.error = error
        self.isFocused = isFocused
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $code, prompt: Text("6-digit code").tracking(0).foregroundStyle(Palette.textTertiary))
                .textStyle(.code)
                .multilineTextAlignment(.center)
                .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(isFocused)
                .padding(.horizontal, Spacing.space4)
                .padding(.vertical, Spacing.space2)
                .frame(minHeight: 60)
                .background(Palette.fill, in: shape)
                .overlay {
                    if let border {
                        shape.strokeBorder(border.color, lineWidth: border.width)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { isFocused.wrappedValue = true }
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(error ?? "")
                .modifier(OptionalIdentifier(identifier: identifier))
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isASCIIDigitCharacter).prefix(6))
                    if digits != newValue { code = digits }
                }
            if let error {
                Text(error)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
                    .modifier(OptionalIdentifier(identifier: identifier.map { "\($0).error" }))
            }
        }
    }

    private var border: (color: Color, width: CGFloat)? {
        let increased = contrast == .increased
        if !isEnabled { return increased ? (Palette.divider, 1) : nil }
        if error != nil { return (Palette.redText, increased ? Size.focusBorderIncreasedContrast : Size.focusBorder) }
        if isFocused.wrappedValue { return (Palette.textPrimary, increased ? Size.focusBorderIncreasedContrast : Size.focusBorder) }
        return increased ? (Palette.controlBorder, 1) : nil
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

/// "Confirm it's you" (A8.18, J0.4) for Move to balance, Delete goal and
/// Change password: title (`title1`), 8 pt, the instruction (`callout`
/// `textSecondary`), 24 pt, "Password" and, with two-factor on,
/// "Authenticator code"; the server's 401 message under the fields
/// (`footnote` `redText`). The action lives in the pinned bar. A 401 here
/// never signs the user out; the password is never stored.
/// `showsTitle: false` drops the title for sheets that already have one.
///
/// `needsPassword: false` (D-41, an account without a password): with
/// `needsCode == true` the code-only variant (the instruction "Enter the
/// 6-digit code from your authenticator app.", 24 pt, "Authenticator code",
/// no Password field); otherwise the title only, with its 8 pt bottom
/// padding, and the caller draws its own body under it. `errorIdentifier`
/// goes on the error line (`account.stepUp.fieldError`).
///
/// Focus (B5.15), both optional: `titleFocus` puts VoiceOver focus on "Confirm
/// it's you" (the caller sets it on appear; without a title it does
/// nothing), and `fieldFocus` binds the keyboard focus of each field drawn
/// (`.password`, `.code`), so the caller can move it back to Password after
/// a 401.
public struct StepUpFields: View {
    /// A field `StepUpFields` draws, for the caller's `fieldFocus`.
    public enum Field: Hashable, Sendable {
        case password, code
    }

    @Binding var password: String
    @Binding var code: String
    let needsCode: Bool?
    let error: String?
    let showsTitle: Bool
    let needsPassword: Bool
    let errorIdentifier: String?
    let titleFocus: AccessibilityFocusState<Bool>.Binding?
    let fieldFocus: FocusState<Field?>.Binding?

    public init(
        password: Binding<String>, code: Binding<String>, needsCode: Bool?, error: String?, showsTitle: Bool = true,
        needsPassword: Bool = true, errorIdentifier: String? = nil,
        titleFocus: AccessibilityFocusState<Bool>.Binding? = nil, fieldFocus: FocusState<Field?>.Binding? = nil
    ) {
        self._password = password
        self._code = code
        self.needsCode = needsCode
        self.error = error
        self.showsTitle = showsTitle
        self.needsPassword = needsPassword
        self.errorIdentifier = errorIdentifier
        self.titleFocus = titleFocus
        self.fieldFocus = fieldFocus
    }

    /// The instruction for the fields drawn; nil when no field is drawn.
    private var instruction: String? {
        switch (needsPassword, needsCode == true) {
        case (true, true): "Enter your password and the 6-digit code from your authenticator app."
        case (true, false): "Enter your password to continue."
        case (false, true): "Enter the 6-digit code from your authenticator app."
        case (false, false): nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text("Confirm it's you")
                    .textStyle(.title1)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(StepUpTitleFocus(binding: titleFocus))
                    .padding(.bottom, Spacing.space2)
            }
            if let instruction {
                Text(instruction)
                    .textStyle(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if needsPassword {
                MoolaTextField(
                    "Password", text: $password, isInvalid: error != nil, isSecure: true,
                    contentType: .password, autocapitalization: .never, autocorrection: false
                )
                .modifier(StepUpFieldFocus(binding: fieldFocus, field: .password))
                .padding(.top, Spacing.space6)
            }
            if needsCode == true {
                MoolaTextField(
                    "Authenticator code", text: $code, placeholder: "6-digit code", isInvalid: error != nil,
                    contentType: .oneTimeCode, keyboard: .numberPad, autocapitalization: .never, autocorrection: false
                )
                .modifier(StepUpFieldFocus(binding: fieldFocus, field: .code))
                .padding(.top, needsPassword ? Spacing.fieldToNextLabel : Spacing.space6)
            }
            if let error {
                Text(error)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
                    .modifier(OptionalIdentifier(identifier: errorIdentifier))
            }
        }
    }
}

/// `StepUpFields`' optional VoiceOver focus on its title.
private struct StepUpTitleFocus: ViewModifier {
    let binding: AccessibilityFocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.accessibilityFocused(binding)
        } else {
            content
        }
    }
}

/// `StepUpFields`' optional keyboard focus on one of its fields.
private struct StepUpFieldFocus: ViewModifier {
    let binding: FocusState<StepUpFields.Field?>.Binding?
    let field: StepUpFields.Field

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: field)
        } else {
            content
        }
    }
}

/// A section heading (A8.24): title (`title3` `textPrimary`) and an optional
/// trailing "See all" whose 44 pt hit region adds no layout height
/// (`SectionLinkStyle`), so the header's frame is the title line and
/// `Spacing.headingToContent` (16) is measured from it. No label above the
/// title, no symbol. `.isHeader`. At accessibility sizes, when the title and
/// the link do not fit on one line, the link moves under the title.
///
/// A count (premium bar DS-5, P6) is a quiet numeral, not part of the title:
/// trailing on the title's first baseline in `amountRow` (16 Medium Rounded,
/// tabular digits) `textSecondary`, no parentheses, no pill, before the link
/// when there is one. VoiceOver and the tests still read one heading,
/// "{title} ({count})" ("Members (4)", "Invitations (1)"), through the
/// heading's accessibility representation.
public struct SectionHeader: View {
    let title: String
    let count: Int?
    let actionTitle: String?
    let actionHint: String?
    let action: (() -> Void)?

    /// - Parameters:
    ///   - count: the number of items in the section, drawn as a muted numeral.
    ///   - actionHint: "Opens Savings.", "Opens Groups.", "Opens Activity." (the label stays "See all").
    public init(
        _ title: String,
        count: Int? = nil,
        actionTitle: String? = nil,
        actionHint: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.count = count
        self.actionTitle = actionTitle
        self.actionHint = actionHint
        self.action = action
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                // With a count, the heading carries its own spacer so the
                // count sits on the trailing edge, just before the link.
                heading
                if count == nil {
                    Spacer(minLength: Spacing.space2)
                }
                link
            }
            VStack(alignment: .leading, spacing: Spacing.space1) {
                heading
                link
            }
        }
    }

    @ViewBuilder
    private var heading: some View {
        if let count {
            HStack(alignment: .firstTextBaseline) {
                titleText
                Spacer(minLength: Spacing.space2)
                Text(verbatim: "\(count)")
                    .textStyle(.amountRow)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityRepresentation {
                Text(verbatim: "\(title) (\(count))")
                    .accessibilityAddTraits(.isHeader)
            }
        } else {
            titleText
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var titleText: some View {
        Text(title)
            .textStyle(.title3)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var link: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .buttonStyle(SectionLinkStyle())
                .accessibilityHint(actionHint ?? "")
        }
    }
}

/// A technical value with Copy (A8.31, B5.13): label (`subheadline`
/// `textSecondary`), 4 pt, value (`body` `textPrimary`, tabular digits, one
/// line, middle truncation, selectable); a trailing plain "Copy"
/// (`subheadlineEmphasis` + `doc.on.doc` 13 pt, ink) on the value's line that
/// copies the full value and shows "Copied" with `checkmark` for 2 s,
/// announced. 12 pt vertical padding (68 pt tall); rows abut with no dividers.
/// A nil value shows "Not set up yet" in `textSecondary` with no Copy. At
/// accessibility sizes the value wraps and Copy moves under it. Render only
/// when the Technical details setting is on. `copyHint` goes on the Copy
/// button only (B5.7: the address's Copy carries "See the note below before
/// you send money here.").
public struct TechnicalDetailsRow: View {
    let label: String
    let value: String?
    let missingText: String
    let copyHint: String?

    @State private var copied = false
    @ScaledMetric(relativeTo: .footnote) private var copySymbol: CGFloat = 13
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(label: String, value: String?, missingText: String = "Not set up yet", copyHint: String? = nil) {
        self.label = label
        self.value = value
        self.missingText = missingText
        self.copyHint = copyHint
    }

    public var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        let layout = accessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space2))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: Spacing.space3))
        layout {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(label)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                valueText(accessibilitySize: accessibilitySize)
            }
            .frame(maxWidth: accessibilitySize ? nil : .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? missingText)
            if let value {
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    AccessibilityNotification.Announcement("Copied").post()
                } label: {
                    HStack(spacing: Spacing.space1) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: copySymbol, weight: .medium))
                        Text(copied ? "Copied" : "Copy")
                            .textStyle(.subheadlineEmphasis)
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.opacity)
                    .frame(minHeight: Size.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(OptionalAccessibilityHint(hint: copyHint))
                .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: copied)
            }
        }
        .padding(.vertical, Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// The value. Selectable at the default sizes. At accessibility sizes it
    /// is drawn with zero-width break points (below), and a selectable text
    /// copies what it draws, so selection is off there: Copy gives the true
    /// value.
    @ViewBuilder
    private func valueText(accessibilitySize: Bool) -> some View {
        let text = Text(value.map { accessibilitySize ? Self.breakableAnywhere($0) : $0 } ?? missingText)
            .textStyle(.body)
            .monospacedDigit()
            .foregroundStyle(value == nil ? Palette.textSecondary : Palette.textPrimary)
            .lineLimit(accessibilitySize ? nil : 1)
            .truncationMode(.middle)
        if accessibilitySize {
            text
        } else {
            text.textSelection(.enabled)
        }
    }

    /// A value that wraps (accessibility sizes) breaks between any two
    /// characters with no hyphen: the system would otherwise hyphenate an
    /// address as if it were a word, showing hyphens that are not in the
    /// data. Drawn text only; VoiceOver and Copy use the true value.
    static func breakableAnywhere(_ value: String) -> String {
        value.map(String.init).joined(separator: "\u{200B}")
    }
}

/// Applies an accessibility hint only when one is given, so a nil hint never
/// replaces one the caller set around the view.
private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

private struct FormFieldsPreview: View {
    @State private var name = ""
    @State private var username = "ama"
    @State private var password = "secret123"
    @State private var stepUpPassword = ""
    @State private var stepUpCode = ""
    @State private var code = ""
    @State private var source: String?
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MoolaTextField("Legal name \u{00B7} private", text: $name, placeholder: "e.g. Ama Mensah", contentType: .name)
                MoolaTextField("Username \u{00B7} public", text: $username, hint: "3\u{2013}30 letters, numbers or underscores", leadingAdornment: "@", autocapitalization: .never, autocorrection: false)
                MoolaTextField("Password", text: $password, error: "Password must be at least 8 characters.", isSecure: true, contentType: .password)
                PickerField(label: "Target amount", value: nil, placeholder: "$0") {}
                PickerField(label: "Date of birth", value: nil, placeholder: "Choose a date", accessibilityValue: "Choose a date", trailingSymbol: "calendar") {}
                ReadOnlyField(label: "Email", value: "demo@moolahub.test") { StatusPill("Verified", tone: .jade) }
                CodeField(code: $code, accessibilityLabel: "Verification code", identifier: "preview.code", error: nil, isFocused: $codeFocused)
                SectionHeader("Your goals", actionTitle: "See all") {}
                TechnicalDetailsRow(label: "Network", value: "Network name")
                TechnicalDetailsRow(label: "Account address", value: nil)
                StepUpFields(password: $stepUpPassword, code: $stepUpCode, needsCode: true, error: "Your password is incorrect.")
                StepUpFields(password: $stepUpPassword, code: $stepUpCode, needsCode: true, error: nil, needsPassword: false)
                PickerMenuField(label: "How did you hear about MoolaHub? \u{00B7} optional", value: nil, placeholder: "Choose one", selection: $source) {
                    Text("Telegram").tag("Telegram" as String?)
                    Text("Friends or family").tag("Friends" as String?)
                }
            }
            .padding(16)
        }
        .moolaCanvas()
    }
}

#Preview("Form fields and rows") {
    FormFieldsPreview()
}
