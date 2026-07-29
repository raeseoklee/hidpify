import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ScreenCaptureKit
import os

private let logger = Logger(subsystem: "dev.irae.hidpify", category: "StreamController")

/// Owns one streaming-mode session's `SCStream` and its physical-display player
/// window (DESIGN.md §9.2). `stop()` tears down both; restoring the physical
/// display's origin is the caller's responsibility (`SessionController`, §4.8),
/// not this type's — `physicalID` is kept only for logging/identification.
public final class StreamSession {
    fileprivate let stream: SCStream
    fileprivate let output: StreamOutputHandler
    fileprivate let window: NSWindow
    public let physicalID: CGDirectDisplayID

    fileprivate init(stream: SCStream, output: StreamOutputHandler, window: NSWindow, physicalID: CGDirectDisplayID) {
        self.stream = stream
        self.output = output
        self.window = window
        self.physicalID = physicalID
    }

    /// Whether this stream is still delivering: ScreenCaptureKit hasn't reported
    /// it stopped (capture error) AND the player window is still on screen. A dead
    /// stream (a `didStopWithError`, or a window that got closed) reads unhealthy
    /// so the daemon can tear it down and recreate it instead of leaving a frozen
    /// black panel (DESIGN.md §9.5). Note: a *static* desktop legitimately sends
    /// no new frames (ScreenCaptureKit is change-driven), so frame arrival is
    /// deliberately NOT used as a liveness signal — only an explicit stop is.
    /// Reads `NSWindow.isVisible`; call on the main thread.
    public var isHealthy: Bool {
        !output.isStopped && window.isVisible
    }

    /// Repositions/resizes the player window to fully cover the physical panel at
    /// its *current* location and size. macOS renormalizes the arrangement (so the
    /// parked "island" origin shifts) and the panel can change resolution/rotation
    /// while streaming; without this the borderless window drifts off the panel,
    /// showing black or a partial frame. Best-effort, main-thread. Returns false
    /// if the physical display has no matching `NSScreen` (e.g. unplugged).
    @discardableResult
    public func refreshWindowFrame() -> Bool {
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) == physicalID } ?? false
        }) else { return false }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
            window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
        }
        // Re-assert on top: a reconfiguration can reorder windows on the panel,
        // which would let the ghost desktop peek through (DESIGN.md §9.5).
        window.orderFrontRegardless()
        return true
    }

    /// Stops capture and closes the player window. Safe to call once; does not
    /// touch display origins (see type doc).
    public func stop() {
        stream.stopCapture { error in
            if let error {
                logger.error("SCStream stopCapture 실패: \(error.localizedDescription, privacy: .public)")
            }
        }
        let window = self.window
        DispatchQueue.main.async {
            window.close()
        }
    }
}

/// Creates and owns the ScreenCaptureKit pipeline for streaming mode
/// (DESIGN.md §9.2): captures the virtual display and mirrors its frames,
/// zero-copy, onto a borderless player window covering the physical display.
public enum StreamController {
    private static var appKitInitialized = false
    private static let streamOutputQueue = DispatchQueue(label: "dev.irae.hidpify.streamcapture")

    public static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system TCC prompt when run from a foreground/interactive
    /// process (DESIGN.md §9.3). No-op (returns current status) if already granted.
    @discardableResult
    public static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Initializes `NSApplication` as a background (Dock/App-Switcher-invisible)
    /// process so `NSWindow`/layer APIs are usable from a CLI/daemon binary
    /// (DESIGN.md §9.2). Idempotent — safe to call more than once.
    public static func ensureAppKitInitialized() {
        guard !appKitInitialized else { return }
        appKitInitialized = true
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Synchronous entry point (bridges ScreenCaptureKit's async API internally
    /// via a semaphore, 5s timeout). Throws `HiDPIError` on any failure; never
    /// leaves a window behind if capture setup fails partway through.
    public static func start(
        virtualID: CGDirectDisplayID,
        physicalID: CGDirectDisplayID,
        refreshRate: Double
    ) throws -> StreamSession {
        ensureAppKitInitialized()

        // Window/layer setup happens synchronously on the calling thread (assumed
        // to be the main thread, as with all other AppKit use in this tool) —
        // deliberately kept outside the `Task` below so it can't deadlock against
        // MainActor work while this thread blocks on the semaphore.
        let window = try makePlayerWindow(physicalID: physicalID)
        let outputHandler = StreamOutputHandler()
        outputHandler.layer = window.contentView?.layer

        let stream: SCStream
        do {
            stream = try runSync(timeout: 5.0) {
                try await setUpAndStartStream(
                    virtualID: virtualID,
                    refreshRate: refreshRate,
                    outputHandler: outputHandler
                )
            }
        } catch {
            window.close()
            throw error
        }

        window.orderFrontRegardless()
        logger.info("stream started: virtual \(virtualID, privacy: .public) → physical \(physicalID, privacy: .public)")
        return StreamSession(stream: stream, output: outputHandler, window: window, physicalID: physicalID)
    }

    // MARK: - ScreenCaptureKit pipeline (async; runs off the calling thread)

    private static func setUpAndStartStream(
        virtualID: CGDirectDisplayID,
        refreshRate: Double,
        outputHandler: StreamOutputHandler
    ) async throws -> SCStream {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw HiDPIError.streamingFailed("SCShareableContent 조회 실패: \(error.localizedDescription)")
        }

        guard let scDisplay = content.displays.first(where: { $0.displayID == virtualID }) else {
            throw HiDPIError.streamingFailed("ScreenCaptureKit에서 가상 디스플레이(\(virtualID))를 찾을 수 없습니다")
        }

        guard let mode = CGDisplayCopyDisplayMode(virtualID) else {
            throw HiDPIError.streamingFailed("가상 디스플레이(\(virtualID))의 현재 모드를 가져올 수 없습니다")
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = mode.pixelWidth
        configuration.height = mode.pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Cap capture at 60fps regardless of the panel's refresh rate. Capturing
        // a full 2x HiDPI backing (e.g. 2556×4544) at 100fps saturates the GPU
        // and stutters the whole system; a desktop rarely needs >60fps of
        // capture, and 60 keeps the cursor/scrolling smooth at a fraction of the
        // cost. `max(30, …)` keeps a sane floor.
        let captureFPS = min(60.0, max(30.0, refreshRate))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(captureFPS))
        configuration.showsCursor = true
        configuration.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: configuration, delegate: outputHandler)

        do {
            try stream.addStreamOutput(outputHandler, type: .screen, sampleHandlerQueue: streamOutputQueue)
            try await stream.startCapture()
        } catch {
            throw HiDPIError.streamingFailed("SCStream 시작 실패: \(error.localizedDescription)")
        }

        return stream
    }

    // MARK: - Player window

    private static func makePlayerWindow(physicalID: CGDirectDisplayID) throws -> NSWindow {
        guard let screen = NSScreen.screens.first(where: { screenMatches($0, physicalID) }) else {
            throw HiDPIError.streamingFailed("물리 디스플레이(\(physicalID))에 대응하는 NSScreen을 찾을 수 없습니다")
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = true
        window.backgroundColor = .black
        // Above normal windows so the physical panel's own "ghost" desktop stays
        // hidden behind the stream even if an app restores a window onto it (the
        // cursor can't reach the island, but window positions can still be
        // restored there). Combined with `.canJoinAllSpaces`/`.fullScreenAuxiliary`
        // below, the player also overlays a ghost fullscreen space. Reduces — but
        // can't fully remove — the ghost desktop (DESIGN.md §9.5).
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.hasShadow = false

        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        contentView.layer?.contentsGravity = .resize
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = contentView

        return window
    }

    private static func screenMatches(_ screen: NSScreen, _ displayID: CGDirectDisplayID) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDirectDisplayID(number.uint32Value) == displayID
    }

    // MARK: - async → sync bridge

    /// Bridges an `async throws` operation to a synchronous call with a timeout.
    /// The operation must not require the calling thread specifically (it runs
    /// on the Swift concurrency thread pool) — see the comment in `start(...)`.
    private static func runSync<T>(timeout: TimeInterval, _ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do {
                box.value = .success(try await operation())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw HiDPIError.streamingFailed("스트리밍 시작이 \(Int(timeout))초 내에 끝나지 않아 타임아웃되었습니다")
        }
        switch box.value {
        case .some(.success(let value)):
            return value
        case .some(.failure(let error)):
            throw error
        case .none:
            throw HiDPIError.streamingFailed("알 수 없는 오류 (결과 없음)")
        }
    }
}

/// Reference box used to pass a `Result` out of a `Task` closure back to the
/// blocking `runSync` caller. `@unchecked Sendable`: the only writer is the
/// `Task`, and `semaphore.wait()` establishes a happens-before edge before
/// the single read.
private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

/// Bridges `SCStream` frames to the player window's `CALayer` via IOSurface
/// (zero-copy, DESIGN.md §9.2 step 5). Runs on a dedicated capture queue; hops
/// to the main queue only to touch the layer.
final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Written once on the main thread before capture starts, then only read —
    /// safe to touch from the capture queue without additional synchronization.
    var layer: CALayer?

    /// Set true when ScreenCaptureKit reports the stream stopped (capture error).
    /// Guarded by `stateLock` since `didStopWithError` and the daemon's health
    /// check (`StreamSession.isHealthy`) run on different threads.
    private let stateLock = NSLock()
    private var _stopped = false
    var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _stopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
            let pixelBuffer = sampleBuffer.imageBuffer,
            let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)
        else { return }
        let surface = surfaceRef.takeUnretainedValue()

        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("SCStream 오류로 중단됨: \(error.localizedDescription, privacy: .public)")
        stateLock.lock()
        _stopped = true
        stateLock.unlock()
    }
}
