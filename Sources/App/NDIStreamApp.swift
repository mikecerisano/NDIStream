import AppKit
import AVFoundation
import Combine

enum DebugLog {
    private static let lock = NSLock()

    static var url: URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        return desktop.appendingPathComponent("NDIStream-debug.log")
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        let header = "NDIStream debug log started \(timestamp())\npath=\(url.path)\n\n"
        try? header.write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ message: String,
                      file: StaticString = #fileID,
                      line: UInt = #line) {
        let lineText = "\(timestamp()) [\(file):\(line)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "NDIStream debug log started \(timestamp())\npath=\(url.path)\n\n".write(to: url, atomically: true, encoding: .utf8)
        }
        guard let data = lineText.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

@MainActor
enum ActivityKeeper {
    private static var reasons: Set<String> = []
    private static var token: NSObjectProtocol?
    private static var keepAliveWindow: NSWindow?

    static func begin(_ reason: String) {
        reasons.insert(reason)
        showKeepAliveWindow()
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .latencyCritical,
                .idleSystemSleepDisabled,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "NDIStream active video: \(reason)"
        )
        DebugLog.write("activity begin reasons=\(Array(reasons).sorted())")
    }

    static func end(_ reason: String) {
        reasons.remove(reason)
        guard reasons.isEmpty, let active = token else { return }
        ProcessInfo.processInfo.endActivity(active)
        token = nil
        hideKeepAliveWindow()
        DebugLog.write("activity end")
    }

    private static func showKeepAliveWindow() {
        guard keepAliveWindow == nil else { return }

        let size = NSSize(width: 2, height: 2)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visibleFrame.maxX - size.width - 1,
            y: visibleFrame.minY + 1,
            width: size.width,
            height: size.height
        )

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.orderFrontRegardless()
        keepAliveWindow = window
        DebugLog.write("keepalive window shown frame=\(NSStringFromRect(frame))")
    }

    private static func hideKeepAliveWindow() {
        guard let window = keepAliveWindow else { return }
        window.orderOut(nil)
        keepAliveWindow = nil
        DebugLog.write("keepalive window hidden")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let senderController = BroadcastController()
    private let receiverModel = ReceiverModel()
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem!
    private var statusBroadcastItem: NSMenuItem!
    private var statusReceiverItem: NSMenuItem!
    private var statusSenderWindowItem: NSMenuItem!
    private var statusReceiverWindowItem: NSMenuItem!
    private var statusHideWindowsItem: NSMenuItem!
    private var statusLineItem: NSMenuItem!

    private var senderWindow: NSWindow!
    private var receiverWindow: NSWindow!

    private var senderCameraDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sourceNameField = NSTextField(string: "")
    private var qualityControl = NSSegmentedControl()
    private var senderTransportControl = NSSegmentedControl()
    private var senderLinkContainer = NSStackView()
    private var senderLinkServerField = NSTextField(string: "")
    private var senderLinkRoomField = NSTextField(string: "")
    private var senderLinkNameField = NSTextField(string: "")
    private var senderLinkTokenField = NSSecureTextField(string: "")
    private var senderLinkButton = NSButton()
    private var senderLinkStatusLabel = NSTextField(labelWithString: "")
    private var senderRoomCodeLabel = NSTextField(labelWithString: "")
    private var senderRoomCodeCopyButton = NSButton()
    private var senderRoomCodeContainer = NSStackView()
    private var fpsControl = NSSegmentedControl()
    private var pixelFormatControl = NSSegmentedControl()
    private var pacingCheckbox = NSButton()
    private var lowestLatencyCheckbox = NSButton()
    private var lowestLatencyPendingLabel = NSTextField(labelWithString: "Pending relaunch")
    private var advancedContainer = NSStackView()
    private var advancedDisclosureButton = NSButton()
    private var senderRecordButton = NSButton()
    private var senderTimerLabel = NSTextField(labelWithString: "00:00")
    private var senderErrorLabel = NSTextField(labelWithString: "")
    private var senderSlateField = NSTextField(string: "")
    private var senderAutoRecordCheckbox = NSButton()
    private var senderLockButton = NSButton()
    private var senderAudioDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
    private var senderAudioCheckbox = NSButton()
    private var senderFolderButton = NSButton()
    private var senderLogButton = NSButton()
    private var logPathLabel = NSTextField(labelWithString: "")
    private var broadcastButton = NSButton()
    private var senderStatusDot = NSView()
    private var senderStatusLabel = NSTextField(labelWithString: "Idle")

    private var receiverSourceDropdown = NSPopUpButton(frame: .zero, pullsDown: false)
    private var receiverConnectButton = NSButton()
    private var receiverStatusLabel = NSTextField(labelWithString: "")
    private var receiverRecordButton = NSButton()
    private var receiverTimerLabel = NSTextField(labelWithString: "00:00")
    private var receiverErrorLabel = NSTextField(labelWithString: "")
    private var receiverSlateField = NSTextField(string: "")
    private var receiverAutoRecordCheckbox = NSButton()
    private var receiverAudioCheckbox = NSButton()
    private var receiverLockButton = NSButton()
    private var receiverFolderButton = NSButton()
    private var receiverTallyDot = NSView()
    private var receiverDisplayHost: DisplayLayerHostNSView!
    private var receiverBorderlessWindow: NSWindow?
    private var receiverBorderlessHost: DisplayLayerHostNSView?
    private var receiverBorderlessKeyMonitor: Any?
    private var receiverBorderlessMouseMonitor: Any?
    private var receiverBorderlessCursorTimer: Timer?
    private var receiverBorderlessMenuItem: NSMenuItem!
    private var receiverTopBar: NSStackView!
    private var receiverBottomBar: NSStackView!
    private var receiverTransportControl = NSSegmentedControl()
    private var receiverLinkContainer = NSStackView()
    private var receiverLinkServerField = NSTextField(string: "")
    private var receiverLinkRoomField = NSTextField(string: "")
    private var receiverLinkNameField = NSTextField(string: "")
    private var receiverLinkTokenField = NSSecureTextField(string: "")
    private var receiverLinkButton = NSButton()
    private var receiverLinkStatusLabel = NSTextField(labelWithString: "")
    private var receiverRoomCodeField = NSTextField(string: "")
    private var receiverJoinByCodeButton = NSButton()
    private var receiverRoomCodeContainer = NSStackView()
    private var receiverTransportRow = NSStackView()

    private var senderStatsOverlay: StatsOverlay?
    private var receiverStatsOverlay: StatsOverlay?
    private var senderStatsMenuItem: NSMenuItem!
    private var receiverStatsMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("applicationDidFinishLaunching")
        DebugLog.write("logPath=\(DebugLog.url.path)")
        NSApp.setActivationPolicy(.regular)
        installMenu()
        installStatusItem()
        buildSenderWindow()
        buildReceiverWindow()
        bindUpdates()
        senderController.refreshCameras()
        updateSenderUI()
        updateReceiverUI()
        senderWindow.makeKeyAndOrderFront(nil)
        receiverWindow.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.write("windows ordered front")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit StageGlass Link", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Edit menu — needed for ⌘C/⌘V/⌘X/⌘A to route to focused text fields.
        // Actions use nil target so AppKit's responder chain delivers them.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Sender", action: #selector(showSenderWindow), keyEquivalent: "1"))
        windowMenu.addItem(NSMenuItem(title: "Receiver", action: #selector(showReceiverWindow), keyEquivalent: "2"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        senderStatsMenuItem = NSMenuItem(title: "Show Sender Stats",
                                          action: #selector(toggleSenderStats),
                                          keyEquivalent: "i")
        senderStatsMenuItem.keyEquivalentModifierMask = [.command]
        senderStatsMenuItem.target = self
        viewMenu.addItem(senderStatsMenuItem)
        receiverStatsMenuItem = NSMenuItem(title: "Show Receiver Stats",
                                            action: #selector(toggleReceiverStats),
                                            keyEquivalent: "I")
        receiverStatsMenuItem.keyEquivalentModifierMask = [.command, .shift]
        receiverStatsMenuItem.target = self
        viewMenu.addItem(receiverStatsMenuItem)

        viewMenu.addItem(NSMenuItem.separator())
        receiverBorderlessMenuItem = NSMenuItem(title: "Enter Borderless Fullscreen",
                                                action: #selector(toggleReceiverBorderless),
                                                keyEquivalent: "F")
        receiverBorderlessMenuItem.keyEquivalentModifierMask = [.command, .shift]
        receiverBorderlessMenuItem.target = self
        viewMenu.addItem(receiverBorderlessMenuItem)

        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Record menu — keyboard shortcuts for toggling recording on each side.
        let recordItem = NSMenuItem()
        let recordMenu = NSMenu(title: "Record")
        let recordSenderItem = NSMenuItem(title: "Toggle Sender Recording",
                                          action: #selector(toggleSenderRecording),
                                          keyEquivalent: "r")
        recordSenderItem.keyEquivalentModifierMask = [.command]
        recordSenderItem.target = self
        recordMenu.addItem(recordSenderItem)
        let recordReceiverItem = NSMenuItem(title: "Toggle Receiver Recording",
                                            action: #selector(toggleReceiverRecording),
                                            keyEquivalent: "R")
        recordReceiverItem.keyEquivalentModifierMask = [.command, .shift]
        recordReceiverItem.target = self
        recordMenu.addItem(recordReceiverItem)
        recordItem.submenu = recordMenu
        mainMenu.addItem(recordItem)

        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Stream"
        statusItem.button?.toolTip = "StageGlass Link"

        let menu = NSMenu()
        statusLineItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        statusBroadcastItem = NSMenuItem(title: "Start Broadcasting", action: #selector(toggleBroadcastFromStatusItem), keyEquivalent: "")
        statusBroadcastItem.target = self
        menu.addItem(statusBroadcastItem)

        statusReceiverItem = NSMenuItem(title: "Connect Receiver", action: #selector(toggleReceiverFromStatusItem), keyEquivalent: "")
        statusReceiverItem.target = self
        menu.addItem(statusReceiverItem)

        menu.addItem(.separator())
        statusSenderWindowItem = NSMenuItem(title: "Show Sender Window", action: #selector(showSenderWindow), keyEquivalent: "")
        statusSenderWindowItem.target = self
        menu.addItem(statusSenderWindowItem)

        statusReceiverWindowItem = NSMenuItem(title: "Show Receiver Window", action: #selector(showReceiverWindow), keyEquivalent: "")
        statusReceiverWindowItem.target = self
        menu.addItem(statusReceiverWindowItem)

        statusHideWindowsItem = NSMenuItem(title: "Hide Windows", action: #selector(hideWindows), keyEquivalent: "")
        statusHideWindowsItem.target = self
        menu.addItem(statusHideWindowsItem)

        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "Open Debug Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit StageGlass Link", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        menu.delegate = self
        statusItem.menu = menu
        DebugLog.write("status item installed")
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in self.updateStatusMenu() }
    }

    private func buildSenderWindow() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        senderTransportControl = NSSegmentedControl(labels: LinkMode.releaseCapabilities.map(\.displayName),
                                                    trackingMode: .selectOne,
                                                    target: self,
                                                    action: #selector(senderTransportChanged))
        senderTransportControl.selectedSegment = AppDelegate.transportIndex(senderController.transport)
        let senderTransportRow = NSStackView(views: [
            NSTextField(labelWithString: "Transport:"),
            senderTransportControl
        ])
        senderTransportRow.spacing = 8
        content.addArrangedSubview(senderTransportRow)
        senderLinkContainer = makeLinkConnectionForm(server: senderLinkServerField,
                                                     room: senderLinkRoomField,
                                                     name: senderLinkNameField,
                                                     token: senderLinkTokenField,
                                                     button: senderLinkButton,
                                                     status: senderLinkStatusLabel,
                                                     action: #selector(toggleSenderLink))
        content.addArrangedSubview(senderLinkContainer)

        content.addArrangedSubview(sectionLabel("Camera"))
        senderCameraDropdown.target = self
        senderCameraDropdown.action = #selector(senderCameraDropdownChanged)
        senderCameraDropdown.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        senderCameraDropdown.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(senderCameraDropdown)

        content.addArrangedSubview(sectionLabel("Microphone"))
        senderAudioDropdown.target = self
        senderAudioDropdown.action = #selector(senderAudioDropdownChanged)
        senderAudioDropdown.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        senderAudioDropdown.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(senderAudioDropdown)

        senderAudioCheckbox = NSButton(checkboxWithTitle: "Send microphone audio", target: self, action: #selector(senderAudioChanged))
        content.addArrangedSubview(senderAudioCheckbox)

        content.addArrangedSubview(sectionLabel("Stream Source Name"))
        sourceNameField.target = self
        sourceNameField.action = #selector(sourceNameEdited)
        sourceNameField.isContinuous = false
        sourceNameField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(sourceNameField)

        content.addArrangedSubview(sectionLabel("Slate (used in recording filename)"))
        senderSlateField.target = self
        senderSlateField.action = #selector(senderSlateEdited)
        senderSlateField.isContinuous = false
        senderSlateField.placeholderString = "e.g. S14T3"
        senderSlateField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(senderSlateField)

        let preview = PreviewNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
        preview.attach(session: senderController.cameraManager.session)
        preview.widthAnchor.constraint(equalToConstant: 400).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 225).isActive = true
        content.addArrangedSubview(preview)

        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 8
        advancedContainer.isHidden = true

        qualityControl = NSSegmentedControl(labels: QualityPreset.allCases.map(\.label), trackingMode: .selectOne, target: self, action: #selector(qualityChanged))
        advancedContainer.addArrangedSubview(labeledRow("Quality", qualityControl))

        fpsControl = NSSegmentedControl(labels: ["30", "60"], trackingMode: .selectOne, target: self, action: #selector(fpsChanged))
        advancedContainer.addArrangedSubview(labeledRow("Frame rate", fpsControl))

        pixelFormatControl = NSSegmentedControl(labels: CapturePixelFormat.allCases.map(\.label), trackingMode: .selectOne, target: self, action: #selector(pixelFormatChanged))
        advancedContainer.addArrangedSubview(labeledRow("Format", pixelFormatControl))

        pacingCheckbox = NSButton(checkboxWithTitle: "Smooth pacing (+1 frame latency)", target: self, action: #selector(pacingChanged))
        advancedContainer.addArrangedSubview(pacingCheckbox)

        lowestLatencyCheckbox = NSButton(checkboxWithTitle: "Lowest latency (unicast UDP, no RUDP; relaunch to apply)", target: self, action: #selector(lowestLatencyChanged))
        advancedContainer.addArrangedSubview(lowestLatencyCheckbox)
        lowestLatencyPendingLabel.textColor = .systemOrange
        lowestLatencyPendingLabel.font = .systemFont(ofSize: 11)
        lowestLatencyPendingLabel.isHidden = true
        advancedContainer.addArrangedSubview(lowestLatencyPendingLabel)

        advancedDisclosureButton.title = "▸  Advanced (quality, frame rate, latency)"
        advancedDisclosureButton.bezelStyle = .inline
        advancedDisclosureButton.setButtonType(.toggle)
        advancedDisclosureButton.target = self
        advancedDisclosureButton.action = #selector(toggleAdvanced)
        advancedDisclosureButton.contentTintColor = .secondaryLabelColor
        advancedDisclosureButton.font = .systemFont(ofSize: 11)
        content.addArrangedSubview(advancedDisclosureButton)
        content.addArrangedSubview(advancedContainer)

        senderAutoRecordCheckbox = NSButton(checkboxWithTitle: "Auto-record when broadcasting starts", target: self, action: #selector(senderAutoRecordChanged))
        content.addArrangedSubview(senderAutoRecordCheckbox)

        let recordRow = row()
        senderRecordButton = NSButton(title: "REC", target: self, action: #selector(toggleSenderRecording))
        senderTimerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        senderErrorLabel.textColor = .systemRed
        senderErrorLabel.lineBreakMode = .byTruncatingMiddle
        senderFolderButton = button("Folder", action: #selector(revealRecordings), width: 70)
        senderLogButton = button("Log", action: #selector(openLog), width: 50)
        senderLockButton = button("🔓", action: #selector(toggleSenderLock), width: 44)
        recordRow.addArrangedSubview(senderRecordButton)
        recordRow.addArrangedSubview(senderTimerLabel)
        recordRow.addArrangedSubview(senderErrorLabel)
        recordRow.addArrangedSubview(senderFolderButton)
        recordRow.addArrangedSubview(senderLogButton)
        recordRow.addArrangedSubview(senderLockButton)
        content.addArrangedSubview(recordRow)

        broadcastButton = NSButton(title: "Start Broadcasting", target: self, action: #selector(toggleBroadcast))
        broadcastButton.bezelStyle = .rounded
        broadcastButton.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(broadcastButton)

        let statusRow = row()
        senderStatusDot.wantsLayer = true
        senderStatusDot.layer?.cornerRadius = 5
        senderStatusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        senderStatusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        senderStatusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        senderStatusLabel.lineBreakMode = .byTruncatingTail
        statusRow.addArrangedSubview(senderStatusDot)
        statusRow.addArrangedSubview(senderStatusLabel)
        content.addArrangedSubview(statusRow)

        senderWindow = makeWindow(title: "StageGlass Link — Sender", content: content, size: NSSize(width: 440, height: 640))
        senderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        resizeSenderWindowToFitContent(animate: false)
    }

    private func buildReceiverWindow() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0

        let topBar = row()
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 4, right: 10)
        receiverTallyDot.wantsLayer = true
        receiverTallyDot.layer?.cornerRadius = 6
        receiverTallyDot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        receiverTallyDot.heightAnchor.constraint(equalToConstant: 12).isActive = true
        topBar.addArrangedSubview(receiverTallyDot)
        receiverSourceDropdown.target = self
        receiverSourceDropdown.action = #selector(receiverSourceDropdownChanged)
        receiverSourceDropdown.widthAnchor.constraint(equalToConstant: 260).isActive = true
        topBar.addArrangedSubview(receiverSourceDropdown)
        receiverConnectButton = NSButton(title: "Connect", target: self, action: #selector(toggleReceiver))
        topBar.addArrangedSubview(receiverConnectButton)
        receiverStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        receiverStatusLabel.lineBreakMode = .byTruncatingTail
        topBar.addArrangedSubview(receiverStatusLabel)

        let bottomBar = row()
        bottomBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 8, right: 10)
        receiverRecordButton = NSButton(title: "REC", target: self, action: #selector(toggleReceiverRecording))
        receiverTimerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        receiverErrorLabel.textColor = .systemRed
        receiverErrorLabel.lineBreakMode = .byTruncatingMiddle
        bottomBar.addArrangedSubview(receiverRecordButton)
        bottomBar.addArrangedSubview(receiverTimerLabel)
        let slateLabel = NSTextField(labelWithString: "Slate")
        slateLabel.textColor = .secondaryLabelColor
        slateLabel.font = .systemFont(ofSize: 11)
        bottomBar.addArrangedSubview(slateLabel)
        receiverSlateField.target = self
        receiverSlateField.action = #selector(receiverSlateEdited)
        receiverSlateField.isContinuous = false
        receiverSlateField.placeholderString = "e.g. S14T3"
        receiverSlateField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        bottomBar.addArrangedSubview(receiverSlateField)
        receiverAutoRecordCheckbox = NSButton(checkboxWithTitle: "Auto-record", target: self, action: #selector(receiverAutoRecordChanged))
        bottomBar.addArrangedSubview(receiverAutoRecordCheckbox)
        receiverAudioCheckbox = NSButton(checkboxWithTitle: "Audio", target: self, action: #selector(receiverAudioChanged))
        bottomBar.addArrangedSubview(receiverAudioCheckbox)
        bottomBar.addArrangedSubview(receiverErrorLabel)
        receiverFolderButton = button("Folder", action: #selector(revealRecordings), width: 64)
        bottomBar.addArrangedSubview(receiverFolderButton)
        receiverLockButton = button("🔓", action: #selector(toggleReceiverLock), width: 44)
        bottomBar.addArrangedSubview(receiverLockButton)

        let display = DisplayLayerHostNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        display.attach(displayLayer: receiverModel.displayLayer)
        display.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        display.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        receiverDisplayHost = display

        receiverTopBar = topBar
        receiverBottomBar = bottomBar

        receiverTransportControl = NSSegmentedControl(labels: LinkMode.releaseCapabilities.map(\.displayName),
                                                       trackingMode: .selectOne,
                                                       target: self,
                                                       action: #selector(receiverTransportChanged))
        receiverTransportControl.selectedSegment = AppDelegate.transportIndex(receiverModel.selectedTransport)
        receiverTransportRow = NSStackView(views: [
            NSTextField(labelWithString: "Transport:"),
            receiverTransportControl
        ])
        receiverTransportRow.spacing = 8
        receiverTransportRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        root.addArrangedSubview(topBar)
        root.addArrangedSubview(receiverTransportRow)
        receiverLinkContainer = makeLinkConnectionForm(server: receiverLinkServerField,
                                                       room: receiverLinkRoomField,
                                                       name: receiverLinkNameField,
                                                       token: receiverLinkTokenField,
                                                       button: receiverLinkButton,
                                                       status: receiverLinkStatusLabel,
                                                       action: #selector(toggleReceiverLink))
        receiverLinkContainer.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        root.addArrangedSubview(receiverLinkContainer)
        root.addArrangedSubview(bottomBar)
        root.addArrangedSubview(display)
        receiverWindow = makeWindow(title: "StageGlass Link — Receiver", content: root, size: NSSize(width: 820, height: 540))
        receiverWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        receiverWindow.level = .floating
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(receiverDidEnterFullScreen),
                                               name: NSWindow.didEnterFullScreenNotification,
                                               object: receiverWindow)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(receiverDidExitFullScreen),
                                               name: NSWindow.didExitFullScreenNotification,
                                               object: receiverWindow)
    }

    @objc private func receiverDidEnterFullScreen() {
        receiverTopBar?.isHidden = true
        receiverBottomBar?.isHidden = true
        receiverTransportRow.isHidden = true
        receiverRoomCodeContainer.isHidden = true
        DebugLog.write("receiver entered fullscreen — bars hidden")
    }

    @objc private func receiverDidExitFullScreen() {
        receiverTopBar?.isHidden = false
        receiverBottomBar?.isHidden = false
        receiverTransportRow.isHidden = false
        // receiverRoomCodeContainer visibility restored by updateReceiverUI()
        updateReceiverUI()
        DebugLog.write("receiver exited fullscreen — bars shown")
    }

    private func bindUpdates() {
        senderController.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSenderUI() }
        }.store(in: &cancellables)
        senderController.recorder.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSenderUI() }
        }.store(in: &cancellables)
        senderController.linkConnection.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSenderUI() }
        }.store(in: &cancellables)
        receiverModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReceiverUI() }
        }.store(in: &cancellables)
        receiverModel.recorder.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReceiverUI() }
        }.store(in: &cancellables)
        receiverModel.linkConnection.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReceiverUI() }
        }.store(in: &cancellables)
    }

    private func updateSenderUI() {
        rebuildSenderCameraDropdown()
        rebuildSenderAudioDropdown()
        sourceNameField.stringValue = senderController.sourceName
        if senderSlateField.stringValue != senderController.slate {
            senderSlateField.stringValue = senderController.slate
        }
        qualityControl.selectedSegment = QualityPreset.allCases.firstIndex(of: senderController.quality) ?? 0
        fpsControl.selectedSegment = senderController.targetFPS == 60 ? 1 : 0
        pixelFormatControl.selectedSegment = CapturePixelFormat.allCases.firstIndex(of: senderController.pixelFormat) ?? 0
        senderAudioCheckbox.state = senderController.audioEnabled ? .on : .off
        pacingCheckbox.state = senderController.smoothPacing ? .on : .off
        lowestLatencyCheckbox.state = senderController.lowestLatency ? .on : .off
        lowestLatencyPendingLabel.isHidden = !senderController.lowestLatencyRelaunchRequired
        senderAutoRecordCheckbox.state = senderController.autoRecord ? .on : .off

        let locked = senderController.isLocked
        senderCameraDropdown.isEnabled = !locked && senderController.availableCameras.count > 0
        senderAudioDropdown.isEnabled = !locked && !senderController.isBroadcasting && senderController.availableAudioDevices.count > 0
        senderAudioCheckbox.isEnabled = !locked && !senderController.isBroadcasting && !senderController.availableAudioDevices.isEmpty
        sourceNameField.isEnabled = !locked && !senderController.isBroadcasting
        senderSlateField.isEnabled = !locked
        qualityControl.isEnabled = !locked
        senderTransportControl.isEnabled = !locked
        fpsControl.isEnabled = !locked
        pixelFormatControl.isEnabled = !locked
        pacingCheckbox.isEnabled = !locked && !senderController.lowestLatency
        lowestLatencyCheckbox.isEnabled = !locked
        senderAutoRecordCheckbox.isEnabled = !locked
        senderRecordButton.isEnabled = !locked && senderController.isBroadcasting
        senderRecordButton.title = senderController.recorder.isRecording ? "STOP REC" : "REC"
        senderTimerLabel.stringValue = formatElapsed(senderController.recorder.elapsed)
        senderErrorLabel.stringValue = senderController.recorder.lastError ?? ""
        broadcastButton.isEnabled = !locked && !senderController.isTransitioning && !senderController.availableCameras.isEmpty
        broadcastButton.title = senderController.isBroadcasting ? "Stop Broadcasting" : "Start Broadcasting"
        senderLockButton.title = locked ? "🔒" : "🔓"
        senderLockButton.toolTip = locked ? "Unlock controls" : "Lock controls (prevents accidental clicks)"
        senderStatusLabel.stringValue = senderStatusText
        senderStatusDot.layer?.backgroundColor = senderStatusColor.cgColor
        updateStatusMenu()
        // Keep transport picker reflecting model state if it changed elsewhere.
        senderTransportControl.selectedSegment = AppDelegate.transportIndex(senderController.transport)
        let link = senderController.linkConnection
        senderLinkContainer.isHidden = senderController.transport != .link
        senderLinkServerField.stringValue = link.serverURL
        senderLinkRoomField.stringValue = link.roomName
        senderLinkNameField.stringValue = link.displayName
        senderLinkButton.title = link.isJoined ? "Leave" : "Join"
        senderLinkButton.isEnabled = !locked && !link.isBusy
        senderLinkStatusLabel.stringValue = link.statusText
        if link.accessToken.isEmpty { senderLinkTokenField.stringValue = "" }
    }

    private func updateReceiverUI() {
        rebuildReceiverSourceDropdown()
        receiverConnectButton.title = receiverModel.isConnected ? "Disconnect" : "Connect"
        let sourceOnline = receiverModel.availableSources.contains(where: { $0.name == receiverModel.selectedSourceName })
        receiverStatusLabel.stringValue = receiverModel.statusLine
        if receiverSlateField.stringValue != receiverModel.slate {
            receiverSlateField.stringValue = receiverModel.slate
        }
        receiverAutoRecordCheckbox.state = receiverModel.autoRecord ? .on : .off
        receiverAudioCheckbox.state = receiverModel.audioEnabled ? .on : .off
        receiverTallyDot.layer?.backgroundColor = receiverTallyColor.cgColor
        receiverTallyDot.toolTip = receiverTallyTooltip

        let locked = receiverModel.isLocked
        receiverSourceDropdown.isEnabled = !locked && !receiverModel.isConnected && receiverModel.availableSources.count > 0
        receiverConnectButton.isEnabled = !locked && (receiverModel.isConnected || sourceOnline)
        receiverSlateField.isEnabled = !locked
        receiverAutoRecordCheckbox.isEnabled = !locked
        receiverAudioCheckbox.isEnabled = !locked
        receiverTransportControl.isEnabled = !locked
        receiverRecordButton.isEnabled = !locked && receiverModel.isConnected
        receiverRecordButton.title = receiverModel.recorder.isRecording ? "STOP REC" : "REC"
        receiverTimerLabel.stringValue = formatElapsed(receiverModel.recorder.elapsed)
        receiverErrorLabel.stringValue = receiverModel.recorder.lastError ?? ""
        receiverLockButton.title = locked ? "🔒" : "🔓"
        receiverLockButton.toolTip = locked ? "Unlock controls" : "Lock controls (prevents accidental clicks)"
        updateStatusMenu()
        // Keep transport picker reflecting model state if it changed elsewhere.
        receiverTransportControl.selectedSegment = AppDelegate.transportIndex(receiverModel.selectedTransport)
        let link = receiverModel.linkConnection
        receiverLinkContainer.isHidden = receiverModel.selectedTransport != .link
        receiverLinkServerField.stringValue = link.serverURL
        receiverLinkRoomField.stringValue = link.roomName
        receiverLinkNameField.stringValue = link.displayName
        receiverLinkButton.title = link.isJoined ? "Leave" : "Join"
        receiverLinkButton.isEnabled = !locked && !link.isBusy
        receiverLinkStatusLabel.stringValue = link.statusText
        if link.accessToken.isEmpty { receiverLinkTokenField.stringValue = "" }
    }

    private var receiverTallyColor: NSColor {
        switch receiverModel.tally {
        case .idle: return .systemGray
        case .waiting: return .systemYellow
        case .live: return .systemGreen
        case .reconnecting: return .systemOrange
        }
    }

    private var receiverTallyTooltip: String {
        switch receiverModel.tally {
        case .idle: return "Idle"
        case .waiting: return "Connecting…"
        case .live: return "Receiving"
        case .reconnecting: return "Reconnecting"
        }
    }

    private func updateStatusMenu() {
        guard statusItem != nil else { return }
        statusItem.button?.title = senderController.isBroadcasting || receiverModel.isConnected ? "Stream ●" : "Stream"
        statusLineItem.title = statusSummary
        statusBroadcastItem.title = senderController.isBroadcasting ? "Stop Broadcasting" : "Start Broadcasting"
        statusBroadcastItem.isEnabled = !senderController.isTransitioning && !senderController.availableCameras.isEmpty
        statusReceiverItem.title = receiverModel.isConnected ? "Disconnect Receiver" : "Connect Receiver"
        statusReceiverItem.isEnabled = receiverModel.isConnected || receiverModel.availableSources.contains(where: { $0.name == receiverModel.selectedSourceName })
        statusSenderWindowItem.isEnabled = senderWindow != nil
        statusReceiverWindowItem.isEnabled = receiverWindow != nil
        statusHideWindowsItem.isEnabled = senderWindow?.isVisible == true || receiverWindow?.isVisible == true
    }

    @objc private func senderCameraDropdownChanged() {
        guard let id = senderCameraDropdown.selectedItem?.representedObject as? String else { return }
        senderController.selectedCameraID = id
    }

    @objc private func senderAudioDropdownChanged() {
        guard let id = senderAudioDropdown.selectedItem?.representedObject as? String else { return }
        senderController.selectedAudioDeviceID = id
    }

    @objc private func receiverSourceDropdownChanged() {
        guard let name = receiverSourceDropdown.selectedItem?.representedObject as? String else { return }
        receiverModel.selectedSourceName = name
    }

    @objc private func sourceNameEdited() { senderController.sourceName = sourceNameField.stringValue }
    @objc private func qualityChanged() { senderController.quality = QualityPreset.allCases[max(0, qualityControl.selectedSegment)] }
    @objc private func fpsChanged() { senderController.targetFPS = fpsControl.selectedSegment == 1 ? 60 : 30 }
    @objc private func pixelFormatChanged() { senderController.pixelFormat = CapturePixelFormat.allCases[max(0, pixelFormatControl.selectedSegment)] }
    @objc private func pacingChanged() { senderController.smoothPacing = pacingCheckbox.state == .on }
    @objc private func lowestLatencyChanged() { senderController.lowestLatency = lowestLatencyCheckbox.state == .on }
    @objc private func toggleBroadcast() { senderController.isBroadcasting ? senderController.stop() : senderController.start() }
    @objc private func toggleBroadcastFromStatusItem() {
        toggleBroadcast()
        DebugLog.write("status item toggle broadcast")
    }
    @objc private func toggleSenderRecording() {
        if senderController.recorder.isRecording {
            senderController.recorder.stop()
        } else {
            senderController.recorder.start(slate: senderController.slate, includeAudio: senderController.audioEnabled)
        }
    }
    @objc private func senderSlateEdited() { senderController.slate = senderSlateField.stringValue }
    @objc private func senderAutoRecordChanged() { senderController.autoRecord = senderAutoRecordCheckbox.state == .on }
    @objc private func senderAudioChanged() {
        senderController.audioEnabled = senderAudioCheckbox.state == .on
        DebugLog.write("sender audio=\(senderController.audioEnabled)")
    }
    @objc private func toggleSenderLock() {
        senderController.isLocked.toggle()
        DebugLog.write("sender lock=\(senderController.isLocked)")
    }

    @objc private func toggleAdvanced() {
        let expanding = advancedDisclosureButton.state == .on
        advancedContainer.isHidden = !expanding
        advancedDisclosureButton.title = expanding
            ? "▾  Advanced (quality, frame rate, latency)"
            : "▸  Advanced (quality, frame rate, latency)"
        resizeSenderWindowToFitContent(animate: true)
        DebugLog.write("advanced expanded=\(expanding)")
    }

    private func resizeSenderWindowToFitContent(animate: Bool) {
        guard let window = senderWindow, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let target = view.fittingSize
        var frame = window.frame
        let currentContentHeight = window.contentRect(forFrameRect: frame).height
        let delta = target.height - currentContentHeight
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: animate)
    }
    @objc private func revealRecordings() { Recorder.revealRecordingsFolder() }
    @objc private func openLog() { NSWorkspace.shared.open(DebugLog.url) }
    @objc private func showSenderWindow() {
        senderWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }
    @objc private func showReceiverWindow() {
        receiverWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }
    @objc private func hideWindows() {
        senderWindow?.orderOut(nil)
        receiverWindow?.orderOut(nil)
        DebugLog.write("windows hidden from status item")
        updateStatusMenu()
    }

    @objc private func toggleReceiver() { receiverModel.isConnected ? receiverModel.disconnect() : receiverModel.connect() }
    @objc private func toggleReceiverFromStatusItem() {
        toggleReceiver()
        DebugLog.write("status item toggle receiver")
    }
    @objc private func toggleReceiverRecording() {
        if receiverModel.recorder.isRecording {
            receiverModel.recorder.stop()
        } else {
            receiverModel.recorder.start(slate: receiverModel.slate, includeAudio: true)
        }
    }
    @objc private func receiverSlateEdited() { receiverModel.slate = receiverSlateField.stringValue }
    @objc private func receiverAutoRecordChanged() { receiverModel.autoRecord = receiverAutoRecordCheckbox.state == .on }
    @objc private func receiverAudioChanged() {
        receiverModel.audioEnabled = receiverAudioCheckbox.state == .on
        DebugLog.write("receiver audio=\(receiverModel.audioEnabled)")
    }
    @objc private func toggleReceiverLock() {
        receiverModel.isLocked.toggle()
        DebugLog.write("receiver lock=\(receiverModel.isLocked)")
    }

    @objc private func toggleReceiverBorderless() {
        if receiverBorderlessWindow != nil {
            exitReceiverBorderless()
        } else {
            enterReceiverBorderless()
        }
    }

    private func enterReceiverBorderless() {
        // Pick the screen that currently contains the receiver window, falling back
        // to the main screen. Borderless covers that whole screen.
        let screen = receiverWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let host = DisplayLayerHostNSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        host.attach(displayLayer: receiverModel.displayLayer)

        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        receiverBorderlessWindow = window
        receiverBorderlessHost = host
        receiverBorderlessMenuItem.title = "Exit Borderless Fullscreen"
        DebugLog.write("receiver entered borderless fullscreen screen=\(screen.localizedName)")

        // Esc exits. Local monitor only fires when this app is key.
        receiverBorderlessKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {   // 53 = Esc
                self?.exitReceiverBorderless()
                return nil
            }
            return event
        }

        // Mouse motion resets the cursor-hide timer and shows the cursor.
        receiverBorderlessMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.borderlessShowCursor()
            self?.scheduleBorderlessCursorHide()
            return event
        }
        scheduleBorderlessCursorHide()
    }

    private func exitReceiverBorderless() {
        guard let window = receiverBorderlessWindow else { return }
        // Move the display layer back to the regular receiver window.
        receiverDisplayHost?.attach(displayLayer: receiverModel.displayLayer)
        window.orderOut(nil)
        receiverBorderlessHost = nil
        receiverBorderlessWindow = nil
        if let mon = receiverBorderlessKeyMonitor { NSEvent.removeMonitor(mon) }
        if let mon = receiverBorderlessMouseMonitor { NSEvent.removeMonitor(mon) }
        receiverBorderlessKeyMonitor = nil
        receiverBorderlessMouseMonitor = nil
        receiverBorderlessCursorTimer?.invalidate()
        receiverBorderlessCursorTimer = nil
        borderlessShowCursor()
        receiverBorderlessMenuItem.title = "Enter Borderless Fullscreen"
        DebugLog.write("receiver exited borderless fullscreen")
    }

    private func scheduleBorderlessCursorHide() {
        receiverBorderlessCursorTimer?.invalidate()
        receiverBorderlessCursorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self, self.receiverBorderlessWindow != nil else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func borderlessShowCursor() {
        // setHiddenUntilMouseMoves auto-reverses on motion; nothing else to do here.
    }

    private func rebuildSenderCameraDropdown() {
        let cameras = senderController.availableCameras
        senderCameraDropdown.removeAllItems()
        guard !cameras.isEmpty else {
            senderCameraDropdown.addItem(withTitle: "No cameras found")
            senderCameraDropdown.item(at: 0)?.isEnabled = false
            return
        }
        for cam in cameras {
            senderCameraDropdown.addItem(withTitle: cam.localizedName)
            senderCameraDropdown.item(at: senderCameraDropdown.numberOfItems - 1)?.representedObject = cam.uniqueID
        }
        let activeID = senderController.selectedCameraID
        if let idx = cameras.firstIndex(where: { $0.uniqueID == activeID }) {
            senderCameraDropdown.selectItem(at: idx)
        } else {
            senderCameraDropdown.selectItem(at: 0)
        }
    }

    private func rebuildSenderAudioDropdown() {
        let devices = senderController.availableAudioDevices
        senderAudioDropdown.removeAllItems()
        guard !devices.isEmpty else {
            senderAudioDropdown.addItem(withTitle: "No microphones found")
            senderAudioDropdown.item(at: 0)?.isEnabled = false
            return
        }
        for dev in devices {
            senderAudioDropdown.addItem(withTitle: dev.localizedName)
            senderAudioDropdown.item(at: senderAudioDropdown.numberOfItems - 1)?.representedObject = dev.uniqueID
        }
        let activeID = senderController.selectedAudioDeviceID
        if let idx = devices.firstIndex(where: { $0.uniqueID == activeID }) {
            senderAudioDropdown.selectItem(at: idx)
        } else {
            senderAudioDropdown.selectItem(at: 0)
        }
    }

    private func rebuildReceiverSourceDropdown() {
        let sources = receiverModel.availableSources
        receiverSourceDropdown.removeAllItems()
        guard !sources.isEmpty else {
            receiverSourceDropdown.addItem(withTitle: "No sources found")
            receiverSourceDropdown.item(at: 0)?.isEnabled = false
            return
        }
        for src in sources {
            receiverSourceDropdown.addItem(withTitle: src.name)
            receiverSourceDropdown.item(at: receiverSourceDropdown.numberOfItems - 1)?.representedObject = src.name
        }
        let activeName = receiverModel.selectedSourceName
        if let idx = sources.firstIndex(where: { $0.name == activeName }) {
            receiverSourceDropdown.selectItem(at: idx)
        } else if !activeName.isEmpty {
            // Selected source went offline — show it greyed at top so the operator can see it's missing.
            receiverSourceDropdown.insertItem(withTitle: "\(activeName) (offline)", at: 0)
            receiverSourceDropdown.item(at: 0)?.isEnabled = false
            receiverSourceDropdown.selectItem(at: 0)
        } else {
            receiverSourceDropdown.selectItem(at: 0)
        }
    }

    private var senderStatusColor: NSColor {
        switch senderController.status {
        case .idle: return .systemGray
        case .live: return .systemGreen
        case .error: return .systemRed
        }
    }

    private var senderStatusText: String {
        switch senderController.status {
        case .idle: return "Idle"
        case .live(let w, let h, let fps):
            if w == 0 || h == 0 { return "Broadcasting as '\(senderController.sourceName)' - starting..." }
            return "Broadcasting as '\(senderController.sourceName)' - \(w)x\(h) @ \(fps) fps"
        case .error(let msg): return msg
        }
    }

    private var statusSummary: String {
        var parts: [String] = []
        if senderController.isBroadcasting {
            parts.append("Sending \(senderController.sourceName)")
        }
        if receiverModel.isConnected {
            parts.append("Receiving")
        }
        if parts.isEmpty {
            return "Idle"
        }
        return parts.joined(separator: " / ")
    }

    private func makeWindow(title: String, content: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.contentView = content
        return window
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
        let stack = row()
        let l = sectionLabel(label)
        l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addArrangedSubview(l)
        stack.addArrangedSubview(control)
        return stack
    }

    private func makeLinkConnectionForm(server: NSTextField,
                                        room: NSTextField,
                                        name: NSTextField,
                                        token: NSSecureTextField,
                                        button: NSButton,
                                        status: NSTextField,
                                        action: Selector) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        for field in [server, room, name, token] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        server.placeholderString = "wss://link.example.com"
        room.placeholderString = "Room"
        name.placeholderString = "Display name"
        token.placeholderString = "Short-lived access token"
        stack.addArrangedSubview(labeledRow("Server", server))
        stack.addArrangedSubview(labeledRow("Room", room))
        stack.addArrangedSubview(labeledRow("Name", name))
        stack.addArrangedSubview(labeledRow("Token", token))
        let actions = row()
        button.target = self
        button.action = action
        actions.addArrangedSubview(button)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        actions.addArrangedSubview(status)
        stack.addArrangedSubview(actions)
        return stack
    }

    private func row() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func button(_ title: String, action: Selector, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Release mode picker helpers

    private static func transportIndex(_ mode: LinkMode) -> Int {
        LinkMode.releaseCapabilities.firstIndex(of: mode) ?? 0
    }

    private static func transportFromIndex(_ index: Int) -> LinkMode {
        LinkMode.releaseCapabilities.indices.contains(index)
            ? LinkMode.releaseCapabilities[index]
            : .link
    }

    @objc private func senderTransportChanged() {
        let new = AppDelegate.transportFromIndex(senderTransportControl.selectedSegment)
        DebugLog.write("UI senderTransportChanged -> \(new.rawValue)")
        senderController.transport = new
        updateSenderUI()
    }

    @objc private func receiverTransportChanged() {
        let new = AppDelegate.transportFromIndex(receiverTransportControl.selectedSegment)
        DebugLog.write("UI receiverTransportChanged -> \(new.rawValue)")
        receiverModel.selectedTransport = new
        updateReceiverUI()
    }

    @objc private func toggleSenderLink() {
        let connection = senderController.linkConnection
        if connection.isJoined {
            Task { await connection.leave() }
            return
        }
        connection.serverURL = senderLinkServerField.stringValue
        connection.roomName = senderLinkRoomField.stringValue
        connection.displayName = senderLinkNameField.stringValue
        connection.accessToken = senderLinkTokenField.stringValue
        connection.saveNonSecretFields(keyPrefix: "sender")
        Task { await connection.join() }
    }

    @objc private func toggleReceiverLink() {
        let connection = receiverModel.linkConnection
        if connection.isJoined {
            Task { await connection.leave() }
            return
        }
        connection.serverURL = receiverLinkServerField.stringValue
        connection.roomName = receiverLinkRoomField.stringValue
        connection.displayName = receiverLinkNameField.stringValue
        connection.accessToken = receiverLinkTokenField.stringValue
        connection.saveNonSecretFields(keyPrefix: "receiver")
        Task { await connection.join() }
    }

    // MARK: Stats overlay (WarpStream integration)

    @objc private func toggleSenderStats() {
        if let overlay = senderStatsOverlay, overlay.isVisible {
            overlay.hide()
            senderStatsMenuItem.title = "Show Sender Stats"
            return
        }
        let overlay = senderStatsOverlay ?? StatsOverlay(
            title: "Sender",
            parent: senderWindow,
            provider: { [weak self] in
                guard let self = self else {
                    return (.ndi, nil)
                }
                return (self.senderController.transport,
                        self.senderController.activeSender?.currentStats())
            }
        )
        senderStatsOverlay = overlay
        overlay.show()
        senderStatsMenuItem.title = "Hide Sender Stats"
    }

    @objc private func toggleReceiverStats() {
        if let overlay = receiverStatsOverlay, overlay.isVisible {
            overlay.hide()
            receiverStatsMenuItem.title = "Show Receiver Stats"
            return
        }
        let overlay = receiverStatsOverlay ?? StatsOverlay(
            title: "Receiver",
            parent: receiverWindow,
            provider: { [weak self] in
                guard let self = self else {
                    return (.ndi, nil)
                }
                return (self.receiverModel.selectedTransport,
                        self.receiverModel.activeReceiver?.currentStats())
            }
        )
        receiverStatsOverlay = overlay
        overlay.show()
        receiverStatsMenuItem.title = "Hide Receiver Stats"
    }
}

@main
enum Main {
    @MainActor private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        DebugLog.reset()
        DebugLog.write("Main.main")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
