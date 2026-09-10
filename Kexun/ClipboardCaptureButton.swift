import SwiftUI

/// The system control grants access only after the user chooses to paste.
struct ClipboardCaptureButton: View {
    let onPaste: (String) -> Void

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            guard !strings.isEmpty else { return }
            onPaste(strings.joined(separator: "\n"))
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .tint(Color(uiColor: KexunPalette.accent))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("clipboardCapturePaste")
    }
}
