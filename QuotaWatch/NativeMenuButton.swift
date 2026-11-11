import SwiftUI
import UIKit

// UIKit owns menu presentation, submenu navigation and dismissal animations.
struct NativeMenuButton: UIViewRepresentable {
    let accessibilityLabel: String
    let menu: () -> UIMenu

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        button.accessibilityLabel = accessibilityLabel
        button.menu = menu()
    }
}
