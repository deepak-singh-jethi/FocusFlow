import SwiftUI
import AppKit

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

    public func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
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

        // Field-scoped focus & selection on initial appearance
        DispatchQueue.main.async {
            guard let window = textField.window else { return }
            window.makeFirstResponder(textField)
            textField.currentEditor()?.selectAll(nil)
        }

        return textField
    }

    public func updateNSView(_ nsView: NSTextField, context: Context) {
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
        weak var textField: NSTextField?
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
                parent.onTab?()
                isHandlingCommand = false
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                isHandlingCommand = true
                parent.onBacktab?()
                isHandlingCommand = false
                return true
            } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                isHandlingCommand = true
                parent.onReturn?()
                isHandlingCommand = false
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                isHandlingCommand = true
                parent.onEscape?()
                isHandlingCommand = false
                return true
            }
            return false
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            guard !isHandlingCommand else { return }
            if let movement = obj.userInfo?["NSTextMovement"] as? Int,
               movement != NSReturnTextMovement,
               movement != NSTabTextMovement,
               movement != NSBacktabTextMovement,
               movement != NSCancelTextMovement {
                parent.onFocusLost?()
            }
        }
    }
}
