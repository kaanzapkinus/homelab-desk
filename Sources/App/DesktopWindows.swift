import AppKit
import SwiftUI

/// DesktopWindows: Manages the native AppKit window lifecycle, dual-window layout
/// (Chat/Management main window + separate compact live metrics panel),
/// system menu-bar status item, desktop/focus/remote window levels,
/// and display frame persistence with boundary clamping.
@MainActor
public final class DesktopWindows: NSObject, NSWindowDelegate {
    private let model: AppModel
    
    // Windows
    private var mainWindow: NSWindow?
    private var metricsPanel: NSPanel?
    private var preferencesWindow: NSWindow?
    private var statusItem: NSStatusItem?
    
    // UserDefaults Keys
    private let desktopWindowFrameKey = "HomelabDesk_DesktopWindowFrame"
    private let desktopWindowDisplayKey = "HomelabDesk_DesktopWindowDisplayID"
    private let remoteWindowFrameKey = "HomelabDesk_RemoteWindowFrame"
    private let remoteWindowDisplayKey = "HomelabDesk_RemoteWindowDisplayID"
    private let metricsPanelFrameKey = "HomelabDesk_MetricsPanelFrame"
    private let metricsPanelDisplayKey = "HomelabDesk_MetricsPanelDisplayID"
    private let mainWindowFrameKey = "HomelabDesk_MainWindowFrame" // legacy fallback key
    private let remoteModeKey = "HomelabDesk_RemoteMode"
    private let windowModeKey = "HomelabDesk_WindowMode"
    
    // Guard against persisting intermediate frames during programmatic layout animations
    private var isApplyingProgrammaticFrame = false
    
    // Level above desktop icons, below ordinary windows
    private var desktopLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
    
    init(model: AppModel) {
        self.model = model
        super.init()
        
        setupMainWindow()
        setupMetricsPanel()
        setupStatusItem()
        setupNotificationObservers()
        
        // Single coherent dispatcher connecting model modes to AppKit actions
        model.onWindowModeChange = { [weak self] mode in
            Task { @MainActor in
                switch mode {
                case .desktop:
                    self?.desktop()
                case .focus:
                    self?.focus()
                case .remote:
                    self?.remote()
                }
            }
        }
        
        
        // Restore previous mode or default to desktop
        let savedMode = UserDefaults.standard.string(forKey: windowModeKey)
        if savedMode == "remote" || UserDefaults.standard.bool(forKey: remoteModeKey) {
            remote()
        } else if savedMode == "focus" {
            focus()
        } else {
            desktop()
        }
        updateWindowDemand()
    }
    
    // MARK: - Public Mode and Navigation APIs
    
    /// Shows the main window and live metrics panel.
    public func show() {
        mainWindow?.makeKeyAndOrderFront(nil)
        metricsPanel?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateWindowDemand()
    }
    
    /// Focus Mode: Temporarily raises the main window to normal level,
    /// making it key and active to guarantee responsive keyboard and paste input.
    public func focus() {
        model.windowMode = .focus
        model.remoteMode = false
        UserDefaults.standard.set("focus", forKey: windowModeKey)
        UserDefaults.standard.set(false, forKey: remoteModeKey)
        
        guard let main = mainWindow else { return }
        main.level = .normal
        main.collectionBehavior = [.canJoinAllSpaces]
        restoreSavedMainWindowFrame()
        main.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateWindowDemand()
    }
    
    /// Desktop Mode: Pins the main window and compact live metrics panel
    /// directly above desktop icons but behind ordinary application windows.
    public func desktop() {
        model.windowMode = .desktop
        model.remoteMode = false
        UserDefaults.standard.set("desktop", forKey: windowModeKey)
        UserDefaults.standard.set(false, forKey: remoteModeKey)
        
        guard let main = mainWindow, let panel = metricsPanel else { return }
        
        main.level = desktopLevel
        main.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        restoreSavedMainWindowFrame()
        main.orderFront(nil)
        
        panel.level = desktopLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.orderFront(nil)
        updateWindowDemand()
    }
    
    /// Remote Mode: Enlarges the main window into an uncluttered 450pt single-column layout
    /// optimized for phone touch control over remote desktop (18pt+ text, 44pt+ buttons).
    public func remote() {
        model.windowMode = .remote
        model.remoteMode = true
        UserDefaults.standard.set("remote", forKey: windowModeKey)
        UserDefaults.standard.set(true, forKey: remoteModeKey)
        
        guard let main = mainWindow else { return }
        
        main.level = .normal
        main.collectionBehavior = [.moveToActiveSpace]
        restoreSavedRemoteWindowFrame()
        main.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateWindowDemand()
    }
    
    /// Opens or brings forward the Preferences window.
    public func showPreferences() {
        if preferencesWindow == nil {
            let prefWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            prefWindow.title = "Homelab Desk Ayarları"
            prefWindow.contentView = NSHostingView(rootView: PreferencesView(model: model))
            prefWindow.center()
            prefWindow.isReleasedWhenClosed = false
            self.preferencesWindow = prefWindow
        }
        
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows or raises the compact live metrics panel.
    @objc public func showMetricsPanel() {
        guard let panel = metricsPanel else { return }
        if panel.level != desktopLevel && model.windowMode == .desktop {
            panel.level = desktopLevel
        }
        panel.orderFront(nil)
        updateWindowDemand()
    }

    /// Toggles visibility of the compact live metrics panel.
    @objc public func toggleMetricsPanel() {
        guard let panel = metricsPanel else { return }
        if panel.isVisible && !panel.isMiniaturized {
            panel.orderOut(nil)
        } else {
            if panel.level != desktopLevel && model.windowMode == .desktop {
                panel.level = desktopLevel
            }
            panel.orderFront(nil)
        }
        updateWindowDemand()
    }

    /// Synchronizes independent window visibility states with monitor demand.
    public func updateWindowDemand() {
        let mainVisible = mainWindow?.isVisible == true && !(mainWindow?.isMiniaturized == true)
        let metricsVisible = metricsPanel?.isVisible == true && !(metricsPanel?.isMiniaturized == true)
        model.monitor.setDemand(mainVisible, for: .mainWindow)
        model.monitor.setDemand(metricsVisible, for: .metricsPanel)
    }
    
    /// Shuts down background monitors and local OMP client session on application termination.
    public func close() {
        model.shutdown()
    }
    
    // MARK: - Window Setup
    
    private func setupMainWindow() {
        let initialRect = NSRect(x: 100, y: 100, width: 980, height: 680)
        let window = KeyReceivingWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Homelab Desk"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: DashboardView(model: model))
        window.minSize = NSSize(width: 420, height: 500)
        
        self.mainWindow = window
        restoreSavedMainWindowFrame()
        window.orderFront(nil)
    }
    
    private func setupMetricsPanel() {
        let panelRect = NSRect(x: 100, y: 100, width: 310, height: 115)
        let panel = KeyReceivingPanel(
            contentRect: panelRect,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.title = "Homelab Metrikleri"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CompactMetricsPanelView(monitor: model.monitor))
        panel.minSize = NSSize(width: 280, height: 100)
        panel.maxSize = NSSize(width: 400, height: 160)
        
        self.metricsPanel = panel
        restoreSavedMetricsPanelFrame()
        panel.orderFront(nil)
    }
    
    // MARK: - Menu Bar Status Item
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Homelab Desk")
        }
        
        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "Homelab Desk", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let desktopItem = NSMenuItem(title: "Masaüstü Modu", action: #selector(menuDesktop), keyEquivalent: "d")
        desktopItem.target = self
        menu.addItem(desktopItem)
        
        let focusItem = NSMenuItem(title: "Odak Modu", action: #selector(menuFocus), keyEquivalent: "f")
        focusItem.target = self
        menu.addItem(focusItem)
        
        let remoteItem = NSMenuItem(title: "Telefon / Uzak Modu", action: #selector(menuRemote), keyEquivalent: "t")
        remoteItem.target = self
        menu.addItem(remoteItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let showMainItem = NSMenuItem(title: "Ana Pencereyi Göster", action: #selector(menuShowMain), keyEquivalent: "1")
        showMainItem.target = self
        menu.addItem(showMainItem)
        
        let showMetricsItem = NSMenuItem(title: "Metrik Panelini Göster", action: #selector(menuShowMetrics), keyEquivalent: "2")
        showMetricsItem.target = self
        menu.addItem(showMetricsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Ayarlar…", action: #selector(menuPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Homelab Desk'ten Çık", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
    }
    
    // MARK: - Menu Actions
    
    @objc private func menuDesktop() { desktop() }
    @objc private func menuFocus() { focus() }
    @objc private func menuRemote() { remote() }
    @objc private func menuShowMain() { show() }
    @objc private func menuShowMetrics() {
        showMetricsPanel()
    }
    @objc private func menuPreferences() { showPreferences() }
    @objc private func menuQuit() {
        close()
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Notifications and Clamping
    
    private func setupNotificationObservers() {
        // Display changes: clamp frames to new screen bounds
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clampAllWindowFrames() }
        }
        
        // Custom app actions
        NotificationCenter.default.addObserver(
            forName: Notification.Name("HomelabDeskFocusWindow"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.focus() }
        }
        
        NotificationCenter.default.addObserver(
            forName: Notification.Name("HomelabDeskShowPreferences"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showPreferences() }
        }
        
        NotificationCenter.default.addObserver(
            forName: Notification.Name("HomelabDeskResetWindowPositions"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetWindowFramesToDefaults() }
        }
        
        NotificationCenter.default.addObserver(
            forName: Notification.Name("HomelabDeskShowMetricsPanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showMetricsPanel() }
        }
        
        NotificationCenter.default.addObserver(
            forName: Notification.Name("HomelabDeskToggleMetricsPanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.toggleMetricsPanel() }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.monitor.setDemand(false, for: .mainWindow)
                self?.model.monitor.setDemand(false, for: .metricsPanel)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateWindowDemand() }
        }
    }
    
    // MARK: - Window Delegate Methods (Persistence & Clamping)
    
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        updateWindowDemand()
        return false
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        updateWindowDemand()
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        updateWindowDemand()
    }
    
    public func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        persistFrame(for: window)
    }
    
    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        persistFrame(for: window)
    }
    
    // MARK: - Screen Resolution and Identifier Helpers
    
    private func screenIdentifier(for screen: NSScreen) -> String {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return screen.localizedName
    }
    
    private func resolveTargetScreen(for savedFrame: NSRect, preferredDisplayID: String?) -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return NSScreen.main ?? NSScreen()
        }
        
        // 1. If we have a saved display identifier, check if that display is still connected
        if let displayID = preferredDisplayID, !displayID.isEmpty {
            if let matchingScreen = screens.first(where: { screenIdentifier(for: $0) == displayID }) {
                return matchingScreen
            }
        }
        
        // 2. Check which connected screen intersects or contains the saved frame
        var bestScreen: NSScreen?
        var maxArea: CGFloat = 0
        for screen in screens {
            let intersection = screen.frame.intersection(savedFrame)
            if !intersection.isNull && !intersection.isEmpty {
                let area = intersection.width * intersection.height
                if area > maxArea {
                    maxArea = area
                    bestScreen = screen
                }
            }
        }
        if let bestScreen = bestScreen, maxArea > 0 {
            return bestScreen
        }
        
        // 3. Check if frame center lies inside any connected screen's frame
        let center = NSPoint(x: savedFrame.midX, y: savedFrame.midY)
        if let containingScreen = screens.first(where: { NSPointInRect(center, $0.frame) }) {
            return containingScreen
        }
        
        // 4. Fall back to NSScreen.main, then first available screen
        return NSScreen.main ?? screens[0]
    }
    
    // MARK: - Frame Persistence & Restoration (Separate Desktop & Remote Frames)
    
    private func persistFrame(for window: NSWindow) {
        guard !isApplyingProgrammaticFrame else { return }
        let frameString = NSStringFromRect(window.frame)
        let displayID = window.screen.map { screenIdentifier(for: $0) } ?? ""
        
        if window === mainWindow {
            if model.windowMode == .remote {
                UserDefaults.standard.set(frameString, forKey: remoteWindowFrameKey)
                UserDefaults.standard.set(displayID, forKey: remoteWindowDisplayKey)
            } else {
                UserDefaults.standard.set(frameString, forKey: desktopWindowFrameKey)
                UserDefaults.standard.set(displayID, forKey: desktopWindowDisplayKey)
                UserDefaults.standard.set(frameString, forKey: mainWindowFrameKey)
            }
        } else if window === metricsPanel {
            UserDefaults.standard.set(frameString, forKey: metricsPanelFrameKey)
            UserDefaults.standard.set(displayID, forKey: metricsPanelDisplayKey)
        }
    }
    
    private func restoreSavedMainWindowFrame() {
        guard let main = mainWindow else { return }
        isApplyingProgrammaticFrame = true
        defer { isApplyingProgrammaticFrame = false }
        
        let savedString = UserDefaults.standard.string(forKey: desktopWindowFrameKey)
            ?? UserDefaults.standard.string(forKey: mainWindowFrameKey)
        let savedDisplayID = UserDefaults.standard.string(forKey: desktopWindowDisplayKey)
        
        if let savedString = savedString {
            let savedFrame = NSRectFromString(savedString)
            let effectiveWidth = max(savedFrame.width, 640)
            let effectiveHeight = max(savedFrame.height, 500)
            let frameToRestore = NSRect(x: savedFrame.origin.x, y: savedFrame.origin.y, width: effectiveWidth, height: effectiveHeight)
            
            let screen = resolveTargetScreen(for: frameToRestore, preferredDisplayID: savedDisplayID)
            let clamped = clamp(frame: frameToRestore, to: screen)
            main.setFrame(clamped, display: true)
            return
        }
        
        // Default placement: Centered on target screen
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen = screen {
            let visible = screen.visibleFrame
            let defaultWidth: CGFloat = 980
            let defaultHeight: CGFloat = 680
            let originX = visible.minX + max(0, (visible.width - defaultWidth) / 2)
            let originY = visible.minY + max(0, (visible.height - defaultHeight) / 2)
            main.setFrame(NSRect(x: originX, y: originY, width: defaultWidth, height: defaultHeight), display: true)
        }
    }
    
    private func restoreSavedRemoteWindowFrame() {
        guard let main = mainWindow else { return }
        isApplyingProgrammaticFrame = true
        defer { isApplyingProgrammaticFrame = false }
        
        let savedString = UserDefaults.standard.string(forKey: remoteWindowFrameKey)
        let savedDisplayID = UserDefaults.standard.string(forKey: remoteWindowDisplayKey)
        
        if let savedString = savedString {
            let savedFrame = NSRectFromString(savedString)
            let width: CGFloat = 450
            let height = max(savedFrame.height, 700)
            let frameToRestore = NSRect(x: savedFrame.origin.x, y: savedFrame.origin.y, width: width, height: height)
            
            let screen = resolveTargetScreen(for: frameToRestore, preferredDisplayID: savedDisplayID)
            let clamped = clamp(frame: frameToRestore, to: screen)
            main.setFrame(clamped, display: true, animate: true)
            return
        }
        
        let targetScreen = main.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = targetScreen {
            var frame = main.frame
            frame.size.width = 450
            frame.size.height = max(frame.size.height, 700)
            let clamped = clamp(frame: frame, to: screen)
            main.setFrame(clamped, display: true, animate: true)
        }
    }
    
    private func restoreSavedMetricsPanelFrame() {
        guard let panel = metricsPanel else { return }
        isApplyingProgrammaticFrame = true
        defer { isApplyingProgrammaticFrame = false }
        
        let savedString = UserDefaults.standard.string(forKey: metricsPanelFrameKey)
        let savedDisplayID = UserDefaults.standard.string(forKey: metricsPanelDisplayKey)
        
        if let savedString = savedString {
            let savedFrame = NSRectFromString(savedString)
            if savedFrame.width > 150 && savedFrame.height > 60 {
                let screen = resolveTargetScreen(for: savedFrame, preferredDisplayID: savedDisplayID)
                let clamped = clamp(frame: savedFrame, to: screen)
                panel.setFrame(clamped, display: true)
                return
            }
        }
        
        // Default placement: Bottom-right corner of screen
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        if let screen = targetScreen {
            let visible = screen.visibleFrame
            let defaultWidth: CGFloat = 310
            let defaultHeight: CGFloat = 115
            let originX = visible.maxX - defaultWidth - 20
            let originY = visible.minY + 20
            panel.setFrame(NSRect(x: originX, y: originY, width: defaultWidth, height: defaultHeight), display: true)
        }
    }
    
    private func clampAllWindowFrames() {
        isApplyingProgrammaticFrame = true
        defer { isApplyingProgrammaticFrame = false }
        
        if let main = mainWindow {
            let screen = resolveTargetScreen(for: main.frame, preferredDisplayID: nil)
            let clamped = clamp(frame: main.frame, to: screen)
            main.setFrame(clamped, display: true)
        }
        if let panel = metricsPanel {
            let screen = resolveTargetScreen(for: panel.frame, preferredDisplayID: nil)
            let clamped = clamp(frame: panel.frame, to: screen)
            panel.setFrame(clamped, display: true)
        }
    }
    
    private func resetWindowFramesToDefaults() {
        UserDefaults.standard.removeObject(forKey: desktopWindowFrameKey)
        UserDefaults.standard.removeObject(forKey: desktopWindowDisplayKey)
        UserDefaults.standard.removeObject(forKey: remoteWindowFrameKey)
        UserDefaults.standard.removeObject(forKey: remoteWindowDisplayKey)
        UserDefaults.standard.removeObject(forKey: mainWindowFrameKey)
        UserDefaults.standard.removeObject(forKey: metricsPanelFrameKey)
        UserDefaults.standard.removeObject(forKey: metricsPanelDisplayKey)
        restoreSavedMainWindowFrame()
        restoreSavedMetricsPanelFrame()
    }
    
    /// Clamps an NSRect strictly inside the visible bounds of the target screen,
    /// preventing window occlusion or off-screen trapping.
    private func clamp(frame: NSRect, to screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var clamped = frame
        
        // Ensure size fits within screen
        clamped.size.width = min(clamped.size.width, visible.width)
        clamped.size.height = min(clamped.size.height, visible.height)
        
        // Clamp Horizontal
        if clamped.minX < visible.minX {
            clamped.origin.x = visible.minX
        } else if clamped.maxX > visible.maxX {
            clamped.origin.x = visible.maxX - clamped.size.width
        }
        
        // Clamp Vertical
        if clamped.minY < visible.minY {
            clamped.origin.y = visible.minY
        } else if clamped.maxY > visible.maxY {
            clamped.origin.y = visible.maxY - clamped.size.height
        }
        
        return clamped
    }
}

// MARK: - Native Windows Guaranteeing Key Focus Without Fake Input Hooks

private final class KeyReceivingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class KeyReceivingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
