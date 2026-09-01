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

        guard let window = focusedWindow(), var frame = frame(of: window) else { return }
        frame.origin.x += x
        frame.origin.y += y
        setPosition(frame.origin, for: window)
    }

    func featureFocusedWindow() {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            return
        }

        guard let window = focusedWindow(), let currentFrame = frame(of: window) else { return }
        guard let screen = screen(containing: currentFrame) else { return }

        let usableFrame = screen.visibleFrame
        let targetSize = CGSize(
            width: usableFrame.width * 0.70,
            height: usableFrame.height * 0.78
        )
        let targetFrame = NSRect(
            x: usableFrame.midX - targetSize.width / 2,
            y: usableFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )

        setSize(targetSize, for: window)
        setPosition(axPosition(for: targetFrame), for: window)
    }

    private func focusedWindow() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success, let focusedWindow else { return nil }
        return (focusedWindow as! AXUIElement)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(for: kAXPositionAttribute as CFString, window: window),
              let sizeValue = axValue(for: kAXSizeAttribute as CFString, window: window) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func axValue(for attribute: CFString, window: AXUIElement) -> AXValue? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &rawValue) == .success,
              let rawValue else { return nil }
        return (rawValue as! AXValue)
    }

    private func setPosition(_ position: CGPoint, for window: AXUIElement) {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, for window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private func screen(containing axFrame: CGRect) -> NSScreen? {
        let axCenter = CGPoint(x: axFrame.midX, y: axFrame.midY)
        let appKitCenter = CGPoint(x: axCenter.x, y: desktopMaximumY - axCenter.y)
        return NSScreen.screens.first(where: { $0.frame.contains(appKitCenter) }) ?? NSScreen.main
    }

    private func axPosition(for appKitFrame: CGRect) -> CGPoint {
        CGPoint(x: appKitFrame.minX, y: desktopMaximumY - appKitFrame.maxY)
    }

    private var desktopMaximumY: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? 0
    }
}

private final class HotKeyController {
    static let shared = HotKeyController()

    private enum Identifier: UInt32 {
        case left = 1, right, down, up
        case largeLeft, largeRight, largeDown, largeUp
        case feature
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
        registerFeatureHotKey()
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
        case .feature: WindowMover.shared.featureFocusedWindow()
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

    private func registerFeatureHotKey() {
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(
            49, // Space
            UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: signature, id: Identifier.feature.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if result == noErr { hotKeys.append(ref) }
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
        let featureWindowItem = menu.addItem(
            withTitle: "Feature window: ⌃⌥⌘ Space",
            action: #selector(featureWindow),
            keyEquivalent: ""
        )
        featureWindowItem.target = self
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

    @objc private func featureWindow() {
        WindowMover.shared.featureFocusedWindow()
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
