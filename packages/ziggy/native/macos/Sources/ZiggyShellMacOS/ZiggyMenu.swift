//
// The desktop menu on MacOS. The core defines the menu as JSON, and this draws it as the application's main menu: the
// application menu first (About and Quit), then the app's own menus. Each item's shortcut becomes its key equivalent, which
// AppKit handles even while the web view has the focus.
//


import AppKit
import WebKit
import CZiggy

// Builds the main menu from the core's menu JSON and carries out the actions the shell owns. Every other action is sent to
// the core as a menu-action message.
final class ZiggyMenu: NSObject {
    // The bridge that owns this menu and the web view the actions work on. Weak, because the bridge owns this menu.
    private weak var bridge: ZiggyBridge?

    // The smallest and largest page zoom the zoom actions reach.
    private static let zoomRange: ClosedRange<Double> = 0.3...5.0

    // The standard edit actions. Each goes to the first responder, which is how they reach the web view.
    private static let responderSelectors: [String: String] = [
        "undo": "undo:",
        "redo": "redo:",
        "cut": "cut:",
        "copy": "copy:",
        "paste": "paste:",
        "select-all": "selectAll:",
    ]

    // Creates the menus from the JSON text the core gave and makes them the application's main menu. The core's own Quit and
    // About items are not drawn in their menus: they are the application menu's Quit and About, so neither appears twice.
    init(bridge: ZiggyBridge, menuJSON: Data) {
        self.bridge = bridge
        super.init()
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: menuJSON)
        }
        catch {
            ZiggyBridge.fail("the core's menu is not valid JSON: \(error)")
        }
        guard let menus = parsed as? [[String: Any]] else {
            ZiggyBridge.fail("the core's menu is not an array of menus")
        }
        let mainMenu = NSMenu()
        mainMenu.addItem(makeApplicationMenuItem(quit: findItem(action: "quit", in: menus), about: findItem(action: "about", in: menus)))
        for menu in menus {
            guard let label = menu["label"] as? String, let entries = menu["items"] as? [[String: Any]] else {
                ZiggyBridge.fail("a menu has no label or no items: \(menu)")
            }
            let submenu = makeSubmenu(label: label, entries: entries)
            if submenu.items.isEmpty {
                continue
            }
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApplication.shared.mainMenu = mainMenu
    }

    // The application menu: About, then Quit, with the shortcut and action the core's items gave when it has them.
    private func makeApplicationMenuItem(quit: [String: Any]?, about: [String: Any]?) -> NSMenuItem {
        guard let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String else {
            ZiggyBridge.fail("the app has no CFBundleName")
        }
        let applicationMenu = NSMenu(title: applicationName)
        if let about = about {
            applicationMenu.addItem(makeItem(title: "About \(applicationName)", entry: about))
        }
        else {
            applicationMenu.addItem(NSMenuItem(title: "About \(applicationName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        }
        applicationMenu.addItem(NSMenuItem.separator())
        if let quit = quit {
            applicationMenu.addItem(makeItem(title: "Quit \(applicationName)", entry: quit))
        }
        else {
            applicationMenu.addItem(NSMenuItem(title: "Quit \(applicationName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        }
        let item = NSMenuItem(title: applicationName, action: nil, keyEquivalent: "")
        item.submenu = applicationMenu
        return item
    }

    // Builds one menu from its entries, leaving out the core's Quit and About items and any separator left at an end or
    // doubled by that.
    private func makeSubmenu(label: String, entries: [[String: Any]]) -> NSMenu {
        let submenu = NSMenu(title: label)
        for entry in entries {
            if entry["separator"] as? Bool == true {
                if let last = submenu.items.last, !last.isSeparatorItem {
                    submenu.addItem(NSMenuItem.separator())
                }
                continue
            }
            let action = entry["action"] as? String
            if action == "quit" || action == "about" {
                continue
            }
            guard let itemLabel = entry["label"] as? String else {
                ZiggyBridge.fail("a menu item has no label: \(entry)")
            }
            if let children = entry["items"] as? [[String: Any]] {
                let child = makeSubmenu(label: itemLabel, entries: children)
                if child.items.isEmpty {
                    continue
                }
                let item = NSMenuItem(title: itemLabel, action: nil, keyEquivalent: "")
                item.submenu = child
                submenu.addItem(item)
                continue
            }
            submenu.addItem(makeItem(title: itemLabel, entry: entry))
        }
        if let last = submenu.items.last, last.isSeparatorItem {
            submenu.removeItem(last)
        }
        return submenu
    }

    // Finds the first item in the menus with the action, however deep.
    private func findItem(action: String, in entries: [[String: Any]]) -> [String: Any]? {
        for entry in entries {
            if entry["action"] as? String == action {
                return entry
            }
            // A menu holds its entries under "items", as does an entry with a submenu.
            if let children = entry["items"] as? [[String: Any]], let found = findItem(action: action, in: children) {
                return found
            }
        }
        return nil
    }

    // Makes the item for an entry: its action, and its shortcut as the key equivalent. A standard edit action goes to the
    // first responder. Every other action comes back to this object.
    private func makeItem(title: String, entry: [String: Any]) -> NSMenuItem {
        guard let action = entry["action"] as? String else {
            ZiggyBridge.fail("the menu item \(title) has no action")
        }
        let item: NSMenuItem
        if let selectorName = ZiggyMenu.responderSelectors[action] {
            item = NSMenuItem(title: title, action: Selector((selectorName)), keyEquivalent: "")
        }
        else {
            item = NSMenuItem(title: title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
        }
        if let text = entry["accelerator"] as? String {
            apply(accelerator: text, to: item)
        }
        return item
    }

    // Reads the shortcut text with the core and sets the item's key equivalent and modifier keys from it.
    private func apply(accelerator text: String, to item: NSMenuItem) {
        var accelerator = ziggy_accelerator()
        let parsed = text.withCString { pointer in
            ziggy_parse_accelerator(pointer, text.utf8.count, &accelerator)
        }
        if !parsed {
            ZiggyBridge.fail("the menu item \(item.title) has a shortcut the core cannot read: \(text)")
        }
        let keyName = withUnsafeBytes(of: accelerator.key) { raw -> String in
            return String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        item.keyEquivalent = ZiggyMenu.keyEquivalent(forKeyName: keyName)
        var mask: NSEvent.ModifierFlags = []
        if accelerator.modifiers & UInt32(ZIGGY_MOD_CTRL) != 0 {
            mask.insert(.control)
        }
        if accelerator.modifiers & UInt32(ZIGGY_MOD_SHIFT) != 0 {
            mask.insert(.shift)
        }
        if accelerator.modifiers & UInt32(ZIGGY_MOD_ALT) != 0 {
            mask.insert(.option)
        }
        if accelerator.modifiers & UInt32(ZIGGY_MOD_META) != 0 {
            mask.insert(.command)
        }
        item.keyEquivalentModifierMask = mask
    }

    // The key equivalent text for the core's key name: the character itself for a letter or digit, and the character AppKit
    // uses for a named key. "plus" is "+", the character a Command and plus shortcut is written with in a menu.
    private static func keyEquivalent(forKeyName name: String) -> String {
        if name.count == 1 {
            return name
        }
        let named: [String: String] = [
            "plus": "+",
            "minus": "-",
            "equal": "=",
            "space": " ",
            "enter": "\r",
            "tab": "\t",
            "escape": "\u{1b}",
            "backspace": "\u{7f}",
            "delete": functionKey(NSDeleteFunctionKey),
            "up": functionKey(NSUpArrowFunctionKey),
            "down": functionKey(NSDownArrowFunctionKey),
            "left": functionKey(NSLeftArrowFunctionKey),
            "right": functionKey(NSRightArrowFunctionKey),
            "home": functionKey(NSHomeFunctionKey),
            "end": functionKey(NSEndFunctionKey),
            "pageup": functionKey(NSPageUpFunctionKey),
            "pagedown": functionKey(NSPageDownFunctionKey),
        ]
        if let text = named[name] {
            return text
        }
        if name.hasPrefix("f"), let number = Int(name.dropFirst()), number >= 1, number <= 35 {
            return functionKey(NSF1FunctionKey + number - 1)
        }
        ZiggyBridge.fail("the menu has a shortcut with a key this shell does not know: \(name)")
    }

    // The one character string AppKit uses for a function key code such as NSF12FunctionKey.
    private static func functionKey(_ code: Int) -> String {
        guard let scalar = UnicodeScalar(UInt32(code)) else {
            ZiggyBridge.fail("not a function key code: \(code)")
        }
        return String(Character(scalar))
    }

    // A menu item the shell does not hand to the responder chain was chosen, by click or by its shortcut.
    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else {
            ZiggyBridge.fail("the menu item \(sender.title) has no action")
        }
        perform(action: action)
    }

    // Does what choosing the menu item for the action does. A menu click and the test control connection both come here,
    // so a test runs exactly what a click runs. An action the shell does not own goes to the core, whatever it is.
    func perform(action: String) {
        guard let bridge = bridge else {
            return
        }
        let webView = bridge.webView
        if let selectorName = ZiggyMenu.responderSelectors[action] {
            // A click reaches the first responder because the web view has the focus. A test may choose the action with no
            // window key or the web view not focused, so it is made so first, and the selector then takes the same route.
            guard let window = webView.window else {
                ZiggyBridge.report("\(action): the web view is not in a window")
                return
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)

            // The undo manager groups the edits made during one event and closes the group when the event ends. A test
            // chooses the action with no event, so the open group is closed here and, except for undo and redo, which work
            // on closed groups, a new one is opened for the action's edit, as the event of a click would.
            if let undoManager = webView.undoManager, undoManager.groupsByEvent {
                // Every open group is closed, not just a single one: undo raises an exception when any group is open ("undo
                // was called with too many nested undo groups"), and the groups the earlier actions opened can add up to more
                // than one before the event that would close them ever runs. The macOS smoke test job of the Ziggy example
                // workflow (run 37458283805, scenario 13-menu-edit) crashed the app with that exception from this method.
                while undoManager.groupingLevel > 0 {
                    undoManager.endUndoGrouping()
                }
                if action != "undo" && action != "redo" {
                    undoManager.beginUndoGrouping()
                }
            }
            if !NSApplication.shared.sendAction(Selector(selectorName), to: nil, from: self) {
                ZiggyBridge.report("\(action): nothing in the responder chain handled \(selectorName)")
            }
            return
        }
        switch action {
        case "close-window":
            guard let window = webView.window else {
                ZiggyBridge.report("close-window: the web view is not in a window")
                return
            }
            window.performClose(nil)
        case "quit":
            NSApplication.shared.terminate(nil)
        case "reload":
            webView.reload()
        case "toggle-devtools":
            toggleDeveloperTools(webView)
        case "toggle-fullscreen":
            guard let window = webView.window else {
                ZiggyBridge.report("toggle-fullscreen: the web view is not in a window")
                return
            }
            window.toggleFullScreen(nil)
        case "zoom-in":
            setZoom(webView, Double(webView.pageZoom) + 0.1)
        case "zoom-out":
            setZoom(webView, Double(webView.pageZoom) - 0.1)
        case "zoom-reset":
            setZoom(webView, 1.0)
        default:
            bridge.postMenuAction(action)
        }
    }

    // Sets the page zoom, rounded to a tenth and kept within the limits.
    private func setZoom(_ webView: WKWebView, _ level: Double) {
        let limited = min(max((level * 10).rounded() / 10, ZiggyMenu.zoomRange.lowerBound), ZiggyMenu.zoomRange.upperBound)
        webView.pageZoom = CGFloat(limited)
    }

    // Shows the web inspector, or hides it when it is showing. The only way to do this programmatically on these SDKs is the
    // private WebKit interface -[WKWebView _inspector] and its show and hide, so each selector is checked first. When one is
    // missing, the message says so and Inspect Element in the context menu still works.
    private func toggleDeveloperTools(_ webView: WKWebView) {
        let inspectorSelector = NSSelectorFromString("_inspector")
        let visibleSelector = NSSelectorFromString("isVisible")
        let showSelector = NSSelectorFromString("show")
        let hideSelector = NSSelectorFromString("hide")
        guard webView.responds(to: inspectorSelector), let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject else {
            ZiggyBridge.report("toggle-devtools: this WebKit has no private _inspector interface. Use Inspect Element in the context menu.")
            return
        }
        guard inspector.responds(to: visibleSelector), inspector.responds(to: showSelector), inspector.responds(to: hideSelector) else {
            ZiggyBridge.report("toggle-devtools: the private inspector has no isVisible, show or hide. Use Inspect Element in the context menu.")
            return
        }
        guard let visible = inspector.value(forKey: "visible") as? Bool else {
            ZiggyBridge.report("toggle-devtools: the private inspector did not say whether it is visible.")
            return
        }
        if visible {
            _ = inspector.perform(hideSelector)
        }
        else {
            _ = inspector.perform(showSelector)
        }
    }
}

