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
        self.selectText(nil)
        if let editor = self.currentEditor() {
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
        placeholder: String = "00",
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

    public func makeNSView(context: Context) -> TimeDigitNSTextField {
        let textField = TimeDigitNSTextField()
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.alignment = .center
        textField.textColor = .white
        textField.focusRingType = .none
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byClipping

        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        if let descriptor = baseFont.fontDescriptor.withDesign(.rounded) {
            textField.font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
        } else {
            textField.font = baseFont
        }

        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: textField.font ?? baseFont
            ]
        )

        textField.stringValue = text
        textField.delegate = context.coordinator
        context.coordinator.textField = textField

        // If already attached to window during creation, activate immediately
        if textField.window != nil && textField.shouldAutoFocusOnMount {
            textField.activateAndSelectAll()
        }

        return textField
    }

    public func updateNSView(_ nsView: TimeDigitNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        if let descriptor = baseFont.fontDescriptor.withDesign(.rounded) {
            nsView.font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
        } else {
            nsView.font = baseFont
        }
    }

    public class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeDigitField
        weak var textField: TimeDigitNSTextField?
        private var isHandlingCommand: Bool = false

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
            if !isKeyboardCommand {
                parent.onFocusLost?()
            }
        }
    }
}
