import SwiftUI
import AppKit

/// AppKit exposes text alignment for the popup cell; SwiftUI's menu Picker
/// does not. The menu, selection marks and keyboard behavior remain native.
struct TrailingOptionPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let choices: [(value: Value, title: String)]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        button.alignment = .right
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        let titles = choices.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = choices.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
        }
        button.alignment = .right
        button.invalidateIntrinsicContentSize()
        button.setAccessibilityLabel(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let textWidth = (nsView.titleOfSelectedItem ?? "").size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return CGSize(width: ceil(textWidth) + 60, height: 28)
    }
    final class Coordinator: NSObject {
        var parent: TrailingOptionPicker
        init(_ parent: TrailingOptionPicker) { self.parent = parent }
        @objc func changed(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard button.isEnabled, parent.choices.indices.contains(index) else { return }
            parent.selection = parent.choices[index].value
        }
    }
}
