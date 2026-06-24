import AppKit
import Carbon
import CoreGraphics
import Foundation
import os

final class HotKeyManager {
    private static let logger = Logger(subsystem: "com.stellarlyyd.padkey", category: "HotKey")

    private var dictationHotKeyRef: EventHotKeyRef?
    private var scratchpadHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var fnEventTap: CFMachPort?
    private var fnRunLoopSource: CFRunLoopSource?
    private var globalFnKeyMonitor: Any?
    private var localFnKeyMonitor: Any?
    private var globalFnMonitor: Any?
    private var localFnMonitor: Any?
    private var fnReleasePollTimer: Timer?
    private var fnIsDown = false

    private var toggleHandler: (() -> Void)?
    private var scratchpadHandler: (() -> Void)?
    private var fnStartHandler: (() -> Void)?
    private var fnStopHandler: (() -> Void)?
    private var diagnosticHandler: ((String) -> Void)?

    func register(
        onToggle: @escaping () -> Void,
        onScratchpad: @escaping () -> Void,
        onFnStart: @escaping () -> Void,
        onFnStop: @escaping () -> Void,
        onDiagnostic: ((String) -> Void)? = nil
    ) {
        unregister()
        toggleHandler = onToggle
        scratchpadHandler = onScratchpad
        fnStartHandler = onFnStart
        fnStopHandler = onFnStop
        diagnosticHandler = onDiagnostic

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let eventHandlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotKey(event)
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        logOSStatus(eventHandlerStatus, operation: "InstallEventHandler")

        let dictationID = EventHotKeyID(signature: Self.fourCharCode("pdky"), id: 1)
        let dictationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            dictationID,
            GetApplicationEventTarget(),
            0,
            &dictationHotKeyRef
        )
        logOSStatus(dictationStatus, operation: "Register Option-Space")

        let scratchpadID = EventHotKeyID(signature: Self.fourCharCode("pdky"), id: 2)
        let scratchpadStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(optionKey),
            scratchpadID,
            GetApplicationEventTarget(),
            0,
            &scratchpadHotKeyRef
        )
        logOSStatus(scratchpadStatus, operation: "Register Option-S")

        installFnMonitor()
    }

    func unregister() {
        if let dictationHotKeyRef {
            UnregisterEventHotKey(dictationHotKeyRef)
            self.dictationHotKeyRef = nil
        }

        if let scratchpadHotKeyRef {
            UnregisterEventHotKey(scratchpadHotKeyRef)
            self.scratchpadHotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        if let fnRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), fnRunLoopSource, .commonModes)
            self.fnRunLoopSource = nil
        }

        if let fnEventTap {
            CGEvent.tapEnable(tap: fnEventTap, enable: false)
            self.fnEventTap = nil
        }

        if let globalFnKeyMonitor {
            NSEvent.removeMonitor(globalFnKeyMonitor)
            self.globalFnKeyMonitor = nil
        }

        if let localFnKeyMonitor {
            NSEvent.removeMonitor(localFnKeyMonitor)
            self.localFnKeyMonitor = nil
        }

        if let globalFnMonitor {
            NSEvent.removeMonitor(globalFnMonitor)
            self.globalFnMonitor = nil
        }

        if let localFnMonitor {
            NSEvent.removeMonitor(localFnMonitor)
            self.localFnMonitor = nil
        }

        fnReleasePollTimer?.invalidate()
        fnReleasePollTimer = nil

        toggleHandler = nil
        scratchpadHandler = nil
        fnStartHandler = nil
        fnStopHandler = nil
        diagnosticHandler = nil
        fnIsDown = false
    }

    private func handleHotKey(_ event: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return }

        switch hotKeyID.id {
        case 1:
            Self.logger.info("Carbon hotkey fired: Option-Space")
            toggleHandler?()
        case 2:
            Self.logger.info("Carbon hotkey fired: Option-S")
            scratchpadHandler?()
        default:
            Self.logger.debug("Unknown Carbon hotkey id: \(hotKeyID.id, privacy: .public)")
            break
        }
    }

    private func installFnMonitor() {
        if !PermissionHelper.isInputMonitoringTrusted {
            emitDiagnostic("Input Monitoring is needed for fn. PadKey will request it; restart the app after granting if fn still does not fire.")
            PermissionHelper.requestInputMonitoring()
        }

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        let keyHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }

        localFnMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: handler)
        globalFnMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: keyHandler)
        globalFnKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        installFnEventTap()
    }

    private func installFnEventTap() {
        let mask =
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue)
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let callback: CGEventTapCallBack = { _, type, event, userData in
            guard let userData else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                manager.emitDiagnostic("fn listener was paused by macOS; PadKey re-enabled it.")
                if let tap = manager.fnEventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            switch type {
            case .flagsChanged:
                manager.handleCGFlagsChanged(event)
            case .keyDown, .keyUp:
                manager.handleCGKeyEvent(event, type: type)
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = createFnEventTap(
            at: .cgSessionEventTap,
            mask: mask,
            callback: callback,
            userData: userData
        ) ?? createFnEventTap(
            at: .cghidEventTap,
            mask: mask,
            callback: callback,
            userData: userData
        ) else {
            emitDiagnostic("Could not start the fn listener. Confirm PadKey is enabled in Input Monitoring, then quit and reopen PadKey.")
            return
        }

        fnEventTap = tap
        fnRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let fnRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), fnRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.logger.info("fn CGEventTap installed and enabled")
        }
    }

    private func createFnEventTap(
        at location: CGEventTapLocation,
        mask: CGEventMask,
        callback: CGEventTapCallBack,
        userData: UnsafeMutableRawPointer
    ) -> CFMachPort? {
        let tap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userData
        )
        let locationDescription = String(describing: location)
        let resultDescription = tap == nil ? "failed" : "ok"
        Self.logger.info("fn CGEventTap create at \(locationDescription, privacy: .public): \(resultDescription, privacy: .public)")
        return tap
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        handleFunctionState(isDown: event.modifierFlags.contains(.function))
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Function) else { return }
        let eventDescription = event.type == .keyDown ? "down" : "up"
        Self.logger.debug("NSEvent fn key \(eventDescription, privacy: .public)")
        handleFunctionState(isDown: event.type == .keyDown)
    }

    private func handleCGFlagsChanged(_ event: CGEvent) {
        let hasFunctionFlag = event.flags.contains(.maskSecondaryFn)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isFunctionKey = keyCode == Int64(kVK_Function)
        if isFunctionKey || hasFunctionFlag {
            Self.logger.debug("CG flagsChanged keyCode=\(keyCode, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) hasFn=\(hasFunctionFlag, privacy: .public)")
        }
        handleFunctionState(isDown: hasFunctionFlag)
    }

    private func handleCGKeyEvent(_ event: CGEvent, type: CGEventType) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_Function) else { return }
        let isDown = type == .keyDown
        Self.logger.debug("CGEvent fn key \(isDown ? "down" : "up", privacy: .public)")
        handleFunctionState(isDown: isDown)
    }

    private func handleFunctionState(isDown hasFunction: Bool) {
        guard hasFunction != fnIsDown else { return }

        fnIsDown = hasFunction
        let handler = hasFunction ? fnStartHandler : fnStopHandler
        let stateDescription = hasFunction ? "down" : "up"
        Self.logger.info("fn state changed: \(stateDescription, privacy: .public)")
        hasFunction ? startFnReleasePollIfNeeded() : stopFnReleasePoll()
        DispatchQueue.main.async {
            handler?()
        }
    }

    private func startFnReleasePollIfNeeded() {
        guard Self.currentFunctionFlagIsDown else { return }
        fnReleasePollTimer?.invalidate()

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.fnIsDown else { return }
            if !Self.currentFunctionFlagIsDown {
                Self.logger.info("fn release detected by state poll")
                self.handleFunctionState(isDown: false)
            }
        }
        fnReleasePollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFnReleasePoll() {
        fnReleasePollTimer?.invalidate()
        fnReleasePollTimer = nil
    }

    private func logOSStatus(_ status: OSStatus, operation: String) {
        if status == noErr {
            Self.logger.info("\(operation, privacy: .public) succeeded")
            return
        }

        emitDiagnostic("\(operation) failed with OSStatus \(status).")
    }

    private func emitDiagnostic(_ message: String) {
        Self.logger.warning("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.diagnosticHandler?(message)
        }
    }

    private static func fourCharCode(_ string: String) -> OSType {
        var result: OSType = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) + OSType(byte)
        }
        return result
    }

    private static var currentFunctionFlagIsDown: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
    }
}
