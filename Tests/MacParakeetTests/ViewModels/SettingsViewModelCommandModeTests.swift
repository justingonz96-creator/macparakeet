import XCTest
import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SettingsViewModelCommandModeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "command-mode-tests-\(UUID().uuidString)")!
    }

    func testCommandModeShortcutPersistsAndReloads() {
        let defaults = makeDefaults()
        let vm = SettingsViewModel(defaults: defaults)
        let shortcut = KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space")
        vm.commandModeShortcut = shortcut
        let reloaded = SettingsViewModel(defaults: defaults)
        XCTAssertEqual(reloaded.commandModeShortcut, shortcut)
    }

    func testClearingCommandModeShortcutPersistsNil() {
        let defaults = makeDefaults()
        let vm = SettingsViewModel(defaults: defaults)
        vm.commandModeShortcut = KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space")
        vm.commandModeShortcut = nil
        let reloaded = SettingsViewModel(defaults: defaults)
        XCTAssertNil(reloaded.commandModeShortcut)
    }
}
