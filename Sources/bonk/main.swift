import AppKit
import ApplicationServices
import Carbon.HIToolbox

private enum Nudge {
    static let small: CGFloat = 1
    static let largeStepKey = "largeNudgeStep"
    static let defaultLarge: CGFloat = 20

    static var large: CGFloat {
        let storedValue = UserDefaults.standard.double(forKey: largeStepKey)
        return storedValue > 0 ? CGFloat(storedValue) : defaultLarge
    }
}

private final class WindowMover {
    static let shared = WindowMover()

    func moveFocusedWindow(x: CGFloat, y: CGFloat) {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            return
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success, let window = focusedWindow else { return }

        let windowElement = window as! AXUIElement
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success, let positionValue else { return }
        let axPosition = positionValue as! AXValue

        var position = CGPoint.zero
        guard AXValueGetValue(axPosition, .cgPoint, &position) else { return }

        position.x += x
        position.y += y
        guard let newPosition = AXValueCreate(.cgPoint, &position) else { return }

        AXUIElementSetAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            newPosition
        )
    }
}

private final class HotKeyController {
    static let shared = HotKeyController()

    private enum Identifier: UInt32 {
        case left = 1, right, down, up
        case largeLeft, largeRight, largeDown, largeUp
    }

    private var hotKeys: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4E554447 // "NUDG"

    func register() {
        let eventTypes = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )]

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            eventTypes.count,
            eventTypes,
            nil,
            &handler
        )

        registerArrows(
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            identifiers: [.left, .right, .down, .up]
        )
        registerArrows(
            modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey),
            identifiers: [.largeLeft, .largeRight, .largeDown, .largeUp]
        )
    }

    func handle(identifier: UInt32) {
        guard let action = Identifier(rawValue: identifier) else { return }
        switch action {
        case .left: WindowMover.shared.moveFocusedWindow(x: -Nudge.small, y: 0)
        case .right: WindowMover.shared.moveFocusedWindow(x: Nudge.small, y: 0)
        case .down: WindowMover.shared.moveFocusedWindow(x: 0, y: Nudge.small)
        case .up: WindowMover.shared.moveFocusedWindow(x: 0, y: -Nudge.small)
        case .largeLeft: WindowMover.shared.moveFocusedWindow(x: -Nudge.large, y: 0)
        case .largeRight: WindowMover.shared.moveFocusedWindow(x: Nudge.large, y: 0)
        case .largeDown: WindowMover.shared.moveFocusedWindow(x: 0, y: Nudge.large)
        case .largeUp: WindowMover.shared.moveFocusedWindow(x: 0, y: -Nudge.large)
        }
    }

    private func registerArrows(modifiers: UInt32, identifiers: [Identifier]) {
        let keys: [UInt32] = [123, 124, 125, 126] // left, right, down, up
        for (key, identifier) in zip(keys, identifiers) {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: identifier.rawValue)
            let result = RegisterEventHotKey(
                key,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if result == noErr { hotKeys.append(ref) }
        }
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let result = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if result == noErr {
        HotKeyController.shared.handle(identifier: hotKeyID.id)
    }
    return noErr
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var largeNudgeMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Nudge.largeStepKey: Nudge.defaultLarge])
        HotKeyController.shared.register()
        configureMenuBar()
        requestAccessibilityIfNeeded()
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "chevron.right.dotted.chevron.right",
            accessibilityDescription: "bonk"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Move: ⌃⌥⌘ Arrow", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Move large: ⌃⌥⇧⌘ Arrow", action: nil, keyEquivalent: "")
        largeNudgeMenuItem = NSMenuItem(title: largeNudgeMenuTitle, action: nil, keyEquivalent: "")
        largeNudgeMenuItem.submenu = makeLargeNudgeMenu()
        menu.addItem(largeNudgeMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enable Accessibility…", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit bonk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openAccessibility() {
        requestAccessibilityIfNeeded()
    }

    private func makeLargeNudgeMenu() -> NSMenu {
        let submenu = NSMenu()
        for step in [10, 20, 25, 30, 40, 50] {
            let item = submenu.addItem(
                withTitle: "\(step) points",
                action: #selector(selectLargeNudge(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = step
            item.state = Nudge.large == CGFloat(step) ? .on : .off
        }
        return submenu
    }

    @objc private func selectLargeNudge(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: Nudge.largeStepKey)
        largeNudgeMenuItem.title = largeNudgeMenuTitle
        largeNudgeMenuItem.submenu?.items.forEach {
            $0.state = $0.tag == sender.tag ? .on : .off
        }
    }

    private var largeNudgeMenuTitle: String {
        "Nudge: \(formattedStep(Nudge.large)) points"
    }

    private func formattedStep(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

private let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
