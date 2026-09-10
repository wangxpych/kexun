import SwiftUI
import UIKit

/// A bounded editor whose insertion point stays visible after edits and layout.
/// Keep UIKit's native selection, undo, paste, and marked-text handling intact.
struct CollectionTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.tintColor = KexunPalette.accent
        view.isScrollEnabled = true
        view.keyboardDismissMode = .interactive
        view.accessibilityLabel = label
        let toolbar = UIToolbar()
        toolbar.tintColor = KexunPalette.accent
        toolbar.sizeToFit()
        let done = UIBarButtonItem(title: String(localized: "收起键盘"), style: .prominent,
                                   target: context.coordinator, action: #selector(Coordinator.dismissKeyboard))
        done.accessibilityIdentifier = "keyboard.dismiss"
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        view.inputAccessoryView = toolbar
        context.coordinator.textView = view
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityLabel = label
        // Never replace a live IME composition or reset selection on a binding echo.
        if view.markedTextRange == nil, view.text != text {
            let selection = view.selectedRange
            view.text = text
            let count = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, count), length: 0)
        }
        if isFocused && !view.isFirstResponder { view.becomeFirstResponder() }
        if !isFocused && view.isFirstResponder { view.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CollectionTextEditor
        weak var textView: UITextView?
        init(parent: CollectionTextEditor) { self.parent = parent }

        @objc func dismissKeyboard() {
            parent.isFocused = false
            textView?.resignFirstResponder()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
            revealInsertionPoint(in: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            revealInsertionPoint(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            revealInsertionPoint(in: textView)
        }

        private func revealInsertionPoint(in textView: UITextView) {
            // Wait for the text layout pass; scrolling before it uses stale geometry.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.isFirstResponder,
                      let selection = textView.selectedTextRange, selection.isEmpty else { return }
                textView.layoutIfNeeded()
                let caret = textView.caretRect(for: selection.end).insetBy(dx: -4, dy: -8)
                textView.scrollRectToVisible(caret, animated: false)
            }
        }
    }
}
