import SwiftUI
import AppKit

// MARK: - Time Digit NSTextField (AppKit subclass for robust, deterministic focus & keyboard navigation)
public final class TimeDigitNSTextField: NSTextField {
    public var shouldAutoFocusOnMount: Bool = true
    public var onFocusAcquired: (() -> Void)?

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && shouldAutoFocusOnMount {
            activateAndSelectAll()
        }
    }

    public func activateAndSelectAll() {
        guard let window = self.window else { return }
        shouldAutoFocusOnMount = false
        window.makeFirstResponder(self)
        if let editor = self.currentEditor() {
            editor.alignment = .center
            editor.selectAll(nil)
        }
        onFocusAcquired?()
    }
}

// MARK: - Time Digit Field (Native AppKit Representable for Field-Scoped Keyboard Navigation)
public struct TimeDigitField: NSViewRepresentable {
    @Binding public var text: String
    public var placeholder: String
    public var fontSize: CGFloat
    public var maxLength: Int
    public var onTab: (() -> Void)?
    public var onBacktab: (() -> Void)?
    public var onReturn: (() -> Void)?
    public var onEscape: (() -> Void)?
    public var onFocusLost: (() -> Void)?

    public init(
        text: Binding<String>,
        placeholder: String = "MM",
        fontSize: CGFloat = 36,
        maxLength: Int = 2,
        onTab: (() -> Void)? = nil,
        onBacktab: (() -> Void)? = nil,
        onReturn: (() -> Void)? = nil,
        onEscape: (() -> Void)? = nil,
        onFocusLost: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.fontSize = fontSize
        self.maxLength = maxLength
        self.onTab = onTab
        self.onBacktab = onBacktab
        self.onReturn = onReturn
        self.onEscape = onEscape
        self.onFocusLost = onFocusLost
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public static func roundedFont(size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = baseFont.fontDescriptor.withDesign(.rounded) else {
            return baseFont
        }
        return NSFont(descriptor: descriptor, size: size) ?? baseFont
    }

    public static func roundedMonospacedFont(size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = baseFont.fontDescriptor.withDesign(.rounded) else {
            return baseFont
        }
        let monoDescriptor = descriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                ]
            ]
        ])
        return NSFont(descriptor: monoDescriptor, size: size) ?? NSFont(descriptor: descriptor, size: size) ?? baseFont
    }

    public static func makePlaceholderAttributedString(
        text: String,
        fontSize: CGFloat,
        color: NSColor = NSColor.white.withAlphaComponent(0.30)
    ) -> NSAttributedString {
        // Optically balanced placeholder font: matches visual mass of digits
        let pSize = max(14, fontSize * 0.78)
        let pFont = roundedFont(size: pSize, weight: .bold)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: pFont,
                .paragraphStyle: style
            ]
        )
    }

    public func makeNSView(context: Context) -> TimeDigitNSTextField {
        let textField = TimeDigitNSTextField()
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.alignment = .center
        textField.cell?.alignment = .center
        textField.textColor = .white
        textField.focusRingType = .none
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byClipping

        let fieldFont = Self.roundedMonospacedFont(size: fontSize, weight: .bold)
        textField.font = fieldFont
        textField.placeholderAttributedString = Self.makePlaceholderAttributedString(
            text: placeholder,
            fontSize: fontSize
        )

        textField.stringValue = text
        textField.delegate = context.coordinator
        context.coordinator.textField = textField
        textField.onFocusAcquired = { [weak coordinator = context.coordinator] in
            coordinator?.hasReportedFocusLost = false
        }

        // If already attached to window during creation, activate immediately
        if textField.window != nil && textField.shouldAutoFocusOnMount {
            textField.activateAndSelectAll()
        }

        return textField
    }

    public func updateNSView(_ nsView: TimeDigitNSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.alignment = .center
        nsView.cell?.alignment = .center
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        let fieldFont = Self.roundedMonospacedFont(size: fontSize, weight: .bold)
        nsView.font = fieldFont
        nsView.placeholderAttributedString = Self.makePlaceholderAttributedString(
            text: placeholder,
            fontSize: fontSize
        )
    }

    public class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeDigitField
        weak var textField: TimeDigitNSTextField?
        private var isHandlingCommand: Bool = false
        public var hasReportedFocusLost: Bool = false

        init(_ parent: TimeDigitField) {
            self.parent = parent
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let tf = textField else { return }
            let raw = tf.stringValue
            let digits = raw.filter { $0.isNumber }
            let capped = String(digits.prefix(parent.maxLength))

            if capped != raw {
                tf.stringValue = capped
            }
            if parent.text != capped {
                parent.text = capped
            }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                isHandlingCommand = true
                defer { isHandlingCommand = false }
                parent.onTab?()
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                isHandlingCommand = true
                defer { isHandlingCommand = false }
                parent.onBacktab?()
                return true
            } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                isHandlingCommand = true
                defer { isHandlingCommand = false }
                parent.onReturn?()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                isHandlingCommand = true
                defer { isHandlingCommand = false }
                parent.onEscape?()
                return true
            }
            return false
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            guard !isHandlingCommand else { return }
            let movement = obj.userInfo?["NSTextMovement"] as? Int
            let isKeyboardCommand = (movement == NSReturnTextMovement ||
                                    movement == NSTabTextMovement ||
                                    movement == NSBacktabTextMovement ||
                                    movement == NSCancelTextMovement)
            guard !isKeyboardCommand else { return }

            if let tf = textField, let window = tf.window {
                DispatchQueue.main.async { [weak self, weak tf, weak window] in
                    guard let self = self, let tf = tf, let window = window else { return }
                    if window.firstResponder === tf || (tf.currentEditor() != nil && window.firstResponder === tf.currentEditor()) {
                        return
                    }
                    guard !self.hasReportedFocusLost else { return }
                    self.hasReportedFocusLost = true
                    self.parent.onFocusLost?()
                }
            } else {
                guard !hasReportedFocusLost else { return }
                hasReportedFocusLost = true
                parent.onFocusLost?()
            }
        }
    }
}
