import AppKit

/// Settings → Menu Bar: which icons show in the menu bar, what clicking one does, and which action
/// buttons the menu starts with. Edits `MenuBarSettings.current` immediately (the app re-applies the icons).
@MainActor
final class MenuBarSettingsSection: NSObject {
    private var iconSwitches: [MenuBarAction: NSSwitch] = [:]
    private var tileSwitches: [MenuBarAction: NSSwitch] = [:]
    private let clickPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private static let iconLabels: [MenuBarAction: String] = [
        .screenshot: "Screenshot icon", .area: "Area icon", .record: "Record icon",
    ]
    private static let tileLabels: [MenuBarAction: String] = [
        .screenshot: "Screenshot button", .area: "Area button", .record: "Record button",
    ]

    func makeView() -> NSView {
        let form = SettingsForm()
        for action in MenuBarAction.available {
            iconSwitches[action] = addSwitch(Self.iconLabels[action] ?? action.title, to: form)
        }
        clickPopup.addItems(withTitles: ["Does its action", "Opens the menu"])
        clickPopup.target = self
        clickPopup.action = #selector(changed)
        clickPopup.toolTip = "Right-click always opens the menu"
        form.addRow("Clicking an icon", clickPopup)
        for action in MenuBarAction.available {
            tileSwitches[action] = addSwitch(Self.tileLabels[action] ?? action.title, to: form)
        }
        load()
        return SettingsStyle.section(
            "Menu Bar", symbol: "menubar.rectangle", tint: .systemPurple, form: form,
            footer: "Buttons show at the top of the menu. Right-click an icon to open the menu; " +
                "⌘-drag icons to rearrange them."
        )
    }

    private func addSwitch(_ label: String, to form: SettingsForm) -> NSSwitch {
        let control = SettingsStyle.makeSwitch()
        control.target = self
        control.action = #selector(changed)
        control.setAccessibilityLabel(label)
        form.addRow(label, control)
        return control
    }

    private func load() {
        let settings = MenuBarSettings.current
        for (action, control) in iconSwitches {
            control.state = settings.icons.contains(action) ? .on : .off
            // The last icon can't be switched off: Skryn would have no way to be reached
            control.isEnabled = !(settings.icons == [action])
        }
        for (action, control) in tileSwitches {
            control.state = settings.menuTiles.contains(action) ? .on : .off
        }
        clickPopup.selectItem(at: settings.clickOpensMenu ? 1 : 0)
    }

    @objc private func changed() {
        var settings = MenuBarSettings.current
        settings.icons = MenuBarAction.available.filter { iconSwitches[$0]?.state == .on }
        settings.menuTiles = MenuBarAction.available.filter { tileSwitches[$0]?.state == .on }
        settings.clickOpensMenu = clickPopup.indexOfSelectedItem == 1
        MenuBarSettings.current = settings
        load()
    }
}
