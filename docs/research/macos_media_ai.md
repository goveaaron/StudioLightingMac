# Prism: macOS Media & AI Integration Reference

*Research date: 2026-11-06.*

| Item | Value |
|---|---|
| Target | macOS 14.0+, with newer APIs behind `@available` / `#available` |
| Toolchain | Xcode 26.x (Swift 6.2/6.3 compiler) |
| Language mode | `swift-tools-version:5.10`, so Swift 5 language mode |
| Distribution | Non-sandboxed, ad-hoc signed |

**Sources**

- macOS **26.5 SDK** headers and `.swiftinterface` files, read directly: CoreAudio (+ Swift overlay), AVFAudio, AVFoundation capture, ScreenCaptureKit, CoreMedia overlay, Speech, FoundationModels.
- Apple developer documentation and WWDC23–25 sessions.
- Open-source implementations:
  - [insidegui/AudioCap](https://github.com/insidegui/AudioCap) (process taps)
  - [makeusabrew/audiotee](https://github.com/makeusabrew/audiotee)
  - the MiniMeters process-tap gist (sudara)
  - karlstav/cava issues
- Official OpenAI, Anthropic and Google Gemini API docs, fetched November 2026.

**Legend**

- ✅ Verified against the SDK or official docs.
- ⚠️ UNVERIFIED: behaviour reported by third parties or inferred. Test it on real hardware before relying on it.

**Conventions used in every code sample**

- **Language mode.** Samples compile in Swift 5 mode with the Xcode 26 compiler, and are written to remain valid under Swift 6 strict concurrency.
- **Isolation.**
  - Objects driven by Core Audio, ScreenCaptureKit or AVCapture callback threads are `final class …: @unchecked Sendable` and guard mutable state with a lock.
  - UI-facing coordinators are `@MainActor`.
- **Closures that run on audio or IO threads are created in `static` (non-isolated) factory functions, or are explicitly `@Sendable`.**
  - A closure literal written inside a `@MainActor` method inherits main-actor isolation. In Swift 6 mode the runtime then traps ("Incorrect actor executor assumption") when Core Audio calls it on its own thread.
  - The SDK does **not** mark `AVAudioNodeTapBlock`, `AVAudioSinkNodeReceiverBlock`, `AudioDeviceIOBlock` or the `SFSpeechRecognizer.requestAuthorization` handler as `@Sendable` (✅ checked in the 26.5 headers), so the compiler will not warn you.
  - `AVAudioConverterInputBlock` and `AVSpeechSynthesizerDelegate` *are* `NS_SWIFT_SENDABLE`.
- **Enums.** Non-frozen SDK enums get an `@unknown default`.

---

## 0. TL;DR

### 0.1 Feature matrix

| Feature | API | Min macOS | Info.plist key | Granted by the user in System Settings ▸ Privacy & Security |
|---|---|---|---|---|
| System audio (primary) | Core Audio **process tap** + private aggregate device | **14.2** | `NSAudioCaptureUsageDescription` | **Screen & System Audio Recording ▸ "System Audio Recording Only"** (macOS 15+). There is no public status API. |
| System audio (fallback) | ScreenCaptureKit `SCStream` audio | 13.0 | none | Screen & System Audio Recording (upper list). Check with `CGPreflightScreenCaptureAccess()` |
| Mic / line-in | `AVAudioEngine` (`AVAudioSinkNode` or `installTap`) | 10.15 | `NSMicrophoneUsageDescription` | Microphone |
| Wake word / commands (any macOS) | `SFSpeechRecognizer`, on-device | 10.15 | `NSSpeechRecognitionUsageDescription` **and** `NSMicrophoneUsageDescription` | Speech Recognition + Microphone |
| Transcription (new) | `SpeechAnalyzer` + `SpeechTranscriber` / `DictationTranscriber` | **26.0** | `NSMicrophoneUsageDescription` only | Microphone |
| Spoken confirmations | `AVSpeechSynthesizer` | 10.14 | none | none |
| On-device LLM | FoundationModels | **26.0**, plus an eligible Apple-silicon Mac with Apple Intelligence turned on | none | (Apple Intelligence & Siri settings) |
| Cloud LLM | `URLSession` REST | any | none (non-sandboxed, so no network entitlement is needed) | none |
| Camera | `AVCaptureSession` + `AVCaptureVideoDataOutput` | 10.7. The `.external` and `.continuityCamera` device types need 14.0 | `NSCameraUsageDescription` (+ `NSCameraUseContinuityCameraDeviceType`) | Camera |

### 0.2 Recommended pipeline

```
Music reactivity : SystemAudioTap (14.2+) ─fallback→ ScreenCaptureAudioSource ─fallback→ MicInputSource (line-in / room mic)
Voice control    : WakeWordListener (SFSpeechRecognizer, 14+)   or   ModernTranscriber (SpeechAnalyzer, 26+)
                   → OnDeviceLightingInterpreter (FoundationModels, 26+)
                   → CloudLLMClient (user-supplied API key)
                   → rule-based parser (always available)
Feedback         : Speaker (AVSpeechSynthesizer) · CameraManager + RegionColor (+ optional cloud vision check)
```

### 0.3 Build & packaging notes (read first)

1. **TCC needs a real `.app` bundle with an Info.plist.**
   - macOS attributes privacy prompts to the *responsible process* and reads usage strings from its Info.plist.
   - A bare SwiftPM executable started from Terminal is attributed to Terminal. Prompts say "Terminal would like…" and the grants go to Terminal.
   - CI must assemble `Prism.app/Contents/{MacOS/Prism, Info.plist, Resources/…}` with a stable `CFBundleIdentifier`, then sign the bundle.
   - Requesting camera, microphone or speech access **without** the matching usage string makes TCC kill the process (✅ documented behaviour). Always ship all the keys below.

   ```xml
   <key>NSMicrophoneUsageDescription</key>
   <string>Prism listens for voice commands and can follow music from a microphone or line-in.</string>
   <key>NSSpeechRecognitionUsageDescription</key>
   <string>Prism turns your voice commands into lighting changes on this Mac.</string>
   <key>NSAudioCaptureUsageDescription</key>
   <string>Prism analyzes the audio your Mac is playing (Spotify, YouTube, …) so the lights can follow the music. Audio is never recorded or uploaded.</string>
   <key>NSCameraUsageDescription</key>
   <string>Prism uses a camera to check that the light on set matches what you asked for.</string>
   <key>NSCameraUseContinuityCameraDeviceType</key>
   <true/>
   ```

   Screen Recording (ScreenCaptureKit) has **no** usage-string key.

2. **Optional, development only: embed the Info.plist into the bare binary** so `swift run` has a bundle ID and usage strings. When the binary is launched from Terminal, prompts may still be attributed to Terminal. Test permissions with `open Prism.app`.

   ```swift
   // Package.swift (sketch — do not apply blindly)
   import Foundation
   let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
       .appendingPathComponent("Sources/PrismApp/Info.plist").path
   // in .executableTarget(name: "PrismApp", …):
   //   exclude: ["Info.plist"],
   //   linkerSettings: [ …, .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
   //                                       "-Xlinker", "__info_plist", "-Xlinker", infoPlist]) ]
   ```

3. **Ad-hoc signing resets privacy grants on every build.**
   - Why: an ad-hoc signature's *designated requirement* (DR) is its `cdhash`, which changes with every build. TCC stores the DR with each grant.
   - Effect after each update, for camera, mic and speech: macOS treats Prism as a new app and **asks again**.
   - Effect for Screen Recording and System Audio Recording: the list can show a stale, enabled-looking entry that no longer matches. The user must remove it with "–" and re-add it (or you reset it with `tccutil`).
   - Options:
     - a. **Recommended: sign with a stable self-signed code-signing certificate.**
       1. Create the certificate once in Keychain Access ▸ Certificate Assistant ▸ Create a Certificate… ▸ type *Code Signing*.
       2. Export it as a `.p12` and store it as a CI secret.
       3. In CI, import it into a temporary keychain and run `codesign --force --sign "Prism Local Signing" Prism.app`.
       - The DR then pins the certificate rather than the cdhash, so grants survive updates. Gatekeeper still needs the first-launch override, exactly as with ad-hoc signing.
       - **Do not** add `--options runtime` (hardened runtime) unless you also add the `com.apple.security.device.audio-input` and `com.apple.security.device.camera` entitlements. Without them the hardened runtime blocks the mic and camera.
     - b. ⚠️ UNVERIFIED hack: ad-hoc sign with an explicit requirement: `codesign -s - -i com.example.prism -r='designated => identifier "com.example.prism"' Prism.app`. This should keep grants but is trivially spoofable. Test it before relying on it.
     - c. During development, reset grants:

   ```bash
   BID=com.example.prism              # your CFBundleIdentifier
   tccutil reset Microphone        "$BID"
   tccutil reset Camera            "$BID"
   tccutil reset SpeechRecognition "$BID"
   tccutil reset ScreenCapture     "$BID"
   tccutil reset AudioCapture      "$BID"   # ⚠️ service name inferred from kTCCServiceAudioCapture
   tccutil reset All               "$BID"   # everything for this bundle id
   ```

4. **FoundationModels must be weak-linked.**
   - Problem: `import FoundationModels` emits an autolink entry, and `FoundationModels.framework` does not exist on macOS 14 or 15. A strong `LC_LOAD_DYLIB` makes dyld abort at launch on those systems.
   - The linker weakens a framework automatically when *every* referenced symbol is weak, which holds when all uses are behind `@available(macOS 26, *)`. Make it explicit anyway, and verify it in CI:

   ```swift
   // PrismApp target, linkerSettings (unsafeFlags are allowed in the root package):
   .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
   ```

   ```bash
   # CI guard: the FoundationModels line must end in ", weak)"
   otool -L Prism.app/Contents/MacOS/Prism | grep FoundationModels
   otool -l Prism.app/Contents/MacOS/Prism | grep -B1 -A3 FoundationModels   # expect cmd LC_LOAD_WEAK_DYLIB
   ```

   The new Speech APIs (`SpeechAnalyzer` etc.) live in `Speech.framework`, which exists on macOS 14, so symbol-level weak references are enough there. Nothing special is needed.

5. **The `@Generable` / `@Guide` macros need full Xcode.** The `FoundationModelsMacros` compiler plugin ships inside Xcode, not the Command Line Tools. On CI, build with `DEVELOPER_DIR=/Applications/Xcode_26.x.app/Contents/Developer`. ⚠️ Verify once that plain `swift build` resolves the plugin on the runner. If it doesn't, build with `xcodebuild -scheme PrismApp`.

6. **ScreenCaptureKit**: `import ScreenCaptureKit` autolinks it, and it exists on 12.3+, so no weak linking is needed. Adding `.linkedFramework("ScreenCaptureKit")` is harmless.

7. **Speech SDK gap.** Apple's online docs mention `AnalyzerInputConverter`, `CaptureInputSequenceProvider` and `AssetInputSequenceProvider`. These are **not in the macOS 26.5 SDK** (✅ checked the swiftinterface), so the sample in §2.2 converts audio itself with `AVAudioConverter`.

---

## 1. System audio capture (react to Spotify / YouTube / any app)

### 1.0 Which source to use

| | Core Audio process tap (§1.2) | ScreenCaptureKit (§1.3) | Mic / line-in (§1.4) |
|---|---|---|---|
| macOS | 14.2+ | 13.0+ for audio | any |
| Permission | "System Audio Recording Only" (`NSAudioCaptureUsageDescription`) | Screen Recording. The prompt is scarier, and macOS 15+ re-confirms periodically | Microphone |
| Can the app read the permission status? | ❌ No public API. Use the silence heuristic or private SPI (§1.2.3) | ✅ `CGPreflightScreenCaptureAccess()` | ✅ `AVCaptureDevice.authorizationStatus(for: .audio)` |
| Pipeline cost | Audio only, one HAL IO cycle of latency | Needs a (tiny) video stream as well | Audio only |
| What it hears | The mix of all processes' output, except the ones you exclude | All audio the display's apps play | The room or the line input |
| Best for | Default choice on 14.2+ | macOS 14.0–14.1, or when the tap stays silent | DJ mixer / line-in, or when nothing is playing on the Mac |

### 1.1 Shared helpers (`AudioSupport.swift`)

```swift
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Receives mono Float32 audio on a capture thread or queue.
/// Copy what you need (e.g. into a ring buffer) and return quickly:
/// no allocation, no locks shared with the UI, no `await`.
/// - samples: valid only for the duration of the call.
/// - hostTime: `mach_absolute_time()` ticks of the first frame, or 0 if unknown.
public typealias MonoSampleHandler = @Sendable (_ samples: UnsafeBufferPointer<Float>,
                                                _ sampleRate: Double,
                                                _ hostTime: UInt64) -> Void

/// Preallocated scratch memory that realtime closures can capture (kept alive by the capture).
public final class ScratchBuffer: @unchecked Sendable {
    public let pointer: UnsafeMutablePointer<Float>
    public let capacity: Int

    public init(capacity: Int = 16_384) {
        self.capacity = capacity
        pointer = .allocate(capacity: capacity)
        pointer.initialize(repeating: 0, count: capacity)
    }

    deinit { pointer.deallocate() }
}

public enum AudioMixdown {
    /// Averages every channel of a Float32 AudioBufferList into `out`.
    /// Works for interleaved buffers, non-interleaved buffers, and mixtures of both.
    /// Returns the number of frames written (≤ capacity). Realtime-safe: no allocation, no locks.
    @inline(__always)
    public static func mono(_ buffers: UnsafeMutableAudioBufferListPointer,
                            into out: UnsafeMutablePointer<Float>,
                            capacity: Int) -> Int {
        var frames = Int.max
        var totalChannels = 0
        for buffer in buffers where buffer.mData != nil && buffer.mNumberChannels > 0 {
            let channels = Int(buffer.mNumberChannels)
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            totalChannels += channels
        }
        guard totalChannels > 0, frames != Int.max else { return 0 }
        frames = min(frames, capacity)
        guard frames > 0 else { return 0 }

        out.update(repeating: 0, count: frames)
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let src = data.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                for f in 0..<frames { out[f] += src[f] }
            } else {
                for f in 0..<frames {
                    var sum: Float = 0
                    let base = f * channels
                    for c in 0..<channels { sum += src[base + c] }
                    out[f] += sum
                }
            }
        }
        let gain = 1 / Float(totalChannels)
        for f in 0..<frames { out[f] *= gain }
        return frames
    }
}

public enum CoreAudioError: Error, CustomStringConvertible {
    case status(OSStatus, call: String)
    case unsupportedFormat(formatID: UInt32, flags: UInt32, bitsPerChannel: UInt32)
    case notFound(String)

    public var description: String {
        switch self {
        case let .status(code, call):
            return "\(call) failed with \(code) \(fourCC(code))"
        case let .unsupportedFormat(id, flags, bits):
            return "Unsupported stream format \(fourCC(OSStatus(bitPattern: id))) flags=\(flags) bits=\(bits)"
        case let .notFound(what):
            return "\(what) not found"
        }
    }
}

/// Renders an OSStatus as a printable four-char code when possible ('nope', '!hog', 'who?').
public func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
    guard bytes.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return "" }
    return "'" + String(decoding: bytes, as: UTF8.self) + "'"
}

@inline(__always)
func check(_ status: OSStatus, _ call: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError.status(status, call: call()) }
}

/// Thin helpers over the AudioObject property API.
public enum CA {
    public static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    public static let unknown = AudioObjectID(kAudioObjectUnknown)

    public static func propertyAddress(_ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size property (AudioObjectID, UInt32, pid_t, AudioStreamBasicDescription, …).
    public static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              initial: T) throws -> T {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "AudioObjectGetPropertyData(\(fourCC(OSStatus(bitPattern: selector))))")
        return value
    }

    /// Reads a CFString property. The HAL returns it +1, hence `takeRetainedValue()`.
    public static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "AudioObjectGetPropertyData(\(fourCC(OSStatus(bitPattern: selector))))")
        guard let string = value?.takeRetainedValue() else { throw CoreAudioError.notFound("string property") }
        return string as String
    }

    /// pid → Core Audio process object (macOS 14.2+ selector 'id2p'). nil if the process has no audio object.
    public static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address,
                                                UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return (status == noErr && object != unknown) ? object : nil
    }

    /// Device UID → AudioObjectID ('uidd', macOS 11+).
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(systemObject, &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        return (status == noErr && device != unknown) ? device : nil
    }

    public static func defaultOutputDeviceUID() throws -> String {
        let device = try get(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: unknown)
        return try getString(device, kAudioDevicePropertyDeviceUID)
    }

    /// True if any *other* process currently has audio output running ('piro', macOS 14.2+).
    /// Note: some players keep their output IO running while paused.
    public static func anyOtherProcessIsPlayingAudio() -> Bool {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var processes = [AudioObjectID](repeating: unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &processes) == noErr else {
            return false
        }
        let myPID = getpid()
        return processes.contains { process in
            let pid = (try? get(process, kAudioProcessPropertyPID, initial: pid_t(0))) ?? 0
            let running = (try? get(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return pid != myPID && running != 0
        }
    }
}

/// Remembers whether a capture stream ever delivered a non-zero sample (permission-denial heuristic).
public final class SilenceMonitor: @unchecked Sendable {
    private struct State {
        var startedAt: UInt64 = 0
        var callbacks = 0
        var sawSignal = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func reset() {
        let now = DispatchTime.now().uptimeNanoseconds
        state.withLock { $0 = State(startedAt: now) }
    }

    /// Call this from the capture callback. It is cheap: the scan stops at the first non-zero sample.
    public func observe(_ samples: UnsafeBufferPointer<Float>) {
        let hasSignal = samples.contains { $0 != 0 }
        state.withLock {
            $0.callbacks += 1
            if hasSignal { $0.sawSignal = true }
        }
    }

    public var snapshot: (seconds: Double, callbacks: Int, sawSignal: Bool) {
        let s = state.withLock { $0 }
        guard s.startedAt != 0 else { return (0, s.callbacks, s.sawSignal) }
        return (Double(DispatchTime.now().uptimeNanoseconds &- s.startedAt) / 1e9, s.callbacks, s.sawSignal)
    }
}
```

### 1.2 Core Audio process tap (macOS 14.2+), the primary source

#### 1.2.1 How it works (✅ 26.5 headers, AudioCap, audiotee, MiniMeters)

1. **Describe the tap.** Build a `CATapDescription`. The class exists since macOS 12; *creating* taps needs 14.2.
   - Swift overlay initializers (✅ in the overlay):
     - `init(stereoMixdownOfProcesses: [AudioObjectID])`
     - `init(monoMixdownOfProcesses:)`
     - `init(stereoGlobalTapButExcludeProcesses: [AudioObjectID])`
     - `init(monoGlobalTapButExcludeProcesses:)`
     - `init(processes:deviceUID:stream:)`
     - `init(excludingProcesses:deviceUID:stream:)`
   - Properties:
     - `name`, `uuid`
     - `processes: [AudioObjectID]`, `isExclusive` (true = "everything except `processes`"), `isMixdown`, `isMono`
     - `isPrivate`, `muteBehavior` (`.unmuted` / `.muted` / `.mutedWhenTapped`)
     - `deviceUID`, `stream: UInt?`
   - macOS 26 additions:
     - `bundleIDs: [String]`, to tap or exclude by bundle ID
     - `isProcessRestoreEnabled`, which re-adds tapped bundle IDs when those apps relaunch
2. **Create the tap.** Call `AudioHardwareCreateProcessTap(description, &tapID)`. Read its ASBD with `kAudioTapPropertyFormat` ('tfmt').
3. **Wrap it in a private aggregate device.** Call `AudioHardwareCreateAggregateDevice(dict, &aggregateID)` with:
   - `kAudioAggregateDeviceTapListKey` ("taps") = `[[kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true]]`
   - `kAudioAggregateDeviceIsPrivateKey: true`
4. **Start IO.** Call `AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, block)`, then `AudioDeviceStart`. The tap audio arrives as the block's *input* `AudioBufferList`.
   - If you pass a dispatch queue, the HAL dispatches the block onto it **synchronously**: the IO thread waits for it.
   - If you pass `nil`, the block runs directly on the realtime IO thread. Keep it cheap either way.
5. **Clean up in this order:** `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.

**Design choice: a *tap-only* aggregate** (as used by MiniMeters in production and by audiotee). `TapAutoStart` is false and there are no sub-devices.

The alternative is AudioCap's approach (§1.2.4), which adds the default output device as the main sub-device with `TapAutoStart = true`. `kAudioAggregateDeviceTapAutoStartKey` makes `AudioDeviceStart` **block until a tapped process produces audio** (✅ header). That is fine when recording one specific app, but wrong for an always-on global analyzer.

#### 1.2.2 `SystemAudioTap.swift`

```swift
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing through a Core Audio process tap wrapped in a
/// private, tap-only aggregate device. Delivers mono Float32 blocks to `handler`.
///
/// Usage:
///     let tap = SystemAudioTap { samples, rate, hostTime in analyzer.push(samples, rate) }
///     try tap.start()          // first call shows the system consent prompt
///     …
///     tap.stop()
///
/// Do not call `stop()` from inside the handler (it would wait on the IO cycle it is running in).
@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {

    public struct Options: Sendable {
        /// Exclude Prism's own audio (UI sounds, previews) from the tap.
        /// AVSpeechSynthesizer output may be rendered by a system process (⚠️) — also gate analysis while speaking.
        public var excludeOwnProcess = true
        /// Rebuild when the default output device changes (sample rate / channel layout can change).
        /// ⚠️ Whether a global tap strictly needs this is unverified; it is cheap insurance.
        public var followDefaultOutputDevice = true
        public init() {}
    }

    private let options: Options
    private let handler: MonoSampleHandler
    private let onFailure: (@Sendable (Error) -> Void)?
    private let scratch = ScratchBuffer(capacity: 16_384)
    private let monitor = SilenceMonitor()
    private let ioQueue = DispatchQueue(label: "prism.system-audio.io", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "prism.system-audio.listener")
    private let controlQueue = DispatchQueue(label: "prism.system-audio.control")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var currentSampleRate: Double = 0
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var pendingRestart: DispatchWorkItem?

    /// - Parameter onFailure: called on a private queue if an automatic rebuild (after a device change) fails.
    public init(options: Options = Options(),
                onFailure: (@Sendable (Error) -> Void)? = nil,
                handler: @escaping MonoSampleHandler) {
        self.options = options
        self.onFailure = onFailure
        self.handler = handler
    }

    deinit {
        // No other strong references exist at this point, so locking is unnecessary.
        pendingRestart?.cancel()
        removeOutputListener()
        teardown()
    }

    public var isRunning: Bool { lock.withLock { running } }
    public var sampleRate: Double { lock.withLock { currentSampleRate } }

    /// Creates tap + aggregate and starts IO. Idempotent.
    /// - Throws: `CoreAudioError` naming the failing call and its OSStatus.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        try build()
        running = true
        installOutputListener()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        pendingRestart?.cancel()
        pendingRestart = nil
        removeOutputListener()
        teardown()
        running = false
    }

    /// ⚠️ Heuristic. Denied (or never-answered) consent raises no error: IO runs normally but every
    /// sample is exactly 0.0. Returns true if we have run for ≥ `seconds`, never saw signal, and some
    /// other process has output IO running. Treat a `true` result as a soft hint ("No audio — check
    /// permission"), not a hard error: some players keep IO running while paused.
    public func looksLikePermissionDenied(after seconds: Double = 3) -> Bool {
        guard isRunning else { return false }
        let s = monitor.snapshot
        guard s.seconds >= seconds, s.callbacks > 0, !s.sawSignal else { return false }
        return CA.anyOtherProcessIsPlayingAudio()
    }

    // MARK: - Graph construction (call with `lock` held)

    private func build() throws {
        do {
            // 1. Stereo mix of every process except (optionally) Prism itself.
            var excluded: [AudioObjectID] = []
            if options.excludeOwnProcess, let me = CA.processObject(for: getpid()) {
                excluded.append(me)
            }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            description.name = "Prism System Audio"
            description.uuid = UUID()
            description.isPrivate = true          // visible only to this process
            description.muteBehavior = .unmuted   // keep playing to the speakers

            // 2. Tap object.
            var newTap = CA.unknown
            try check(AudioHardwareCreateProcessTap(description, &newTap), "AudioHardwareCreateProcessTap")
            tapID = newTap

            // 3. Tap format: normally Float32 stereo at the output device's nominal rate.
            let format = try CA.get(newTap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw CoreAudioError.unsupportedFormat(formatID: format.mFormatID,
                                                       flags: format.mFormatFlags,
                                                       bitsPerChannel: format.mBitsPerChannel)
            }
            currentSampleRate = format.mSampleRate

            // 4. Private aggregate device whose only input is the tap.
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Prism System Audio Tap",
                kAudioAggregateDeviceUIDKey: "com.prism.system-audio-tap.\(UUID().uuidString)", // must be unique
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ] as [String: Any],
                ],
            ]
            var newAggregate = CA.unknown
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate),
                      "AudioHardwareCreateAggregateDevice")
            aggregateID = newAggregate

            // 5. IO block → mono mixdown → handler.
            let block = Self.makeIOBlock(handler: handler, scratch: scratch, monitor: monitor,
                                         sampleRate: format.mSampleRate)
            var procID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, newAggregate, ioQueue, block),
                      "AudioDeviceCreateIOProcIDWithBlock")
            ioProcID = procID

            // 6. Start IO. The first start for this app shows the "System Audio Recording" consent prompt.
            monitor.reset()
            try check(AudioDeviceStart(newAggregate, procID), "AudioDeviceStart")
        } catch {
            teardown()
            throw error
        }
    }

    /// Static so that the block can never inherit actor isolation. Captures only thread-safe objects.
    private static func makeIOBlock(handler: @escaping MonoSampleHandler,
                                    scratch: ScratchBuffer,
                                    monitor: SilenceMonitor,
                                    sampleRate: Double) -> AudioDeviceIOBlock {
        return { _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let frames = AudioMixdown.mono(buffers, into: scratch.pointer, capacity: scratch.capacity)
            guard frames > 0 else { return }
            let samples = UnsafeBufferPointer(start: scratch.pointer, count: frames)
            monitor.observe(samples)
            let time = inputTime.pointee
            handler(samples, sampleRate, time.mFlags.contains(.hostTimeValid) ? time.mHostTime : 0)
        }
    }

    /// Order matters: stop IO → destroy IO proc → destroy aggregate → destroy tap.
    private func teardown() {
        if aggregateID != CA.unknown {
            if let procID = ioProcID {
                _ = AudioDeviceStop(aggregateID, procID)
                _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != CA.unknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = CA.unknown
        tapID = CA.unknown
    }

    // MARK: - Default-output-device changes

    private func installOutputListener() {
        guard options.followDefaultOutputDevice, outputListener == nil else { return }
        // Keep the block object: removal requires the *identical* block.
        // Never take `lock` inside it — stop() holds the lock while removing the listener.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.controlQueue.async { [weak self] in self?.scheduleRestart() }
        }
        var address = CA.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(CA.systemObject, &address, listenerQueue, listener) == noErr {
            outputListener = listener
        }
    }

    private func removeOutputListener() {
        guard let listener = outputListener else { return }
        var address = CA.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectRemovePropertyListenerBlock(CA.systemObject, &address, listenerQueue, listener)
        outputListener = nil
    }

    /// Runs on controlQueue. Debounces bursts of device notifications.
    private func scheduleRestart() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRestart = work
        controlQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func rebuild() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        pendingRestart = nil
        teardown()
        do {
            try build()
        } catch {
            running = false          // listener stays installed until stop()/deinit; it is inert now
            onFailure?(error)
        }
    }
}
```

Choosing the source at the call site:

```swift
func startMusicInput(analyzer: AudioAnalyzer) async {
    if #available(macOS 14.2, *) {
        let tap = SystemAudioTap { samples, rate, hostTime in analyzer.push(samples, sampleRate: rate, hostTime: hostTime) }
        do {
            try tap.start()
            self.systemTap = tap
            try? await Task.sleep(for: .seconds(4))
            if tap.looksLikePermissionDenied() { showSystemAudioPermissionHint() }  // see §6
            return
        } catch {
            log("Process tap failed: \(error) — falling back to ScreenCaptureKit")
        }
    }
    // macOS 14.0/14.1, or the tap failed: ScreenCaptureKit (§1.3), then the mic (§1.4).
}
```

#### 1.2.3 Permission behaviour

- **Info.plist:** `NSAudioCaptureUsageDescription` is required (✅ AudioCap). No entitlement is needed for a non-sandboxed app.
- **When the prompt appears:** the system prompt is shown the first time IO starts on an aggregate device that contains a tap (`AudioDeviceStart`). It is **not** shown on creation (✅ AudioCap notes).
- **Denial is silent:** no API returns an error. The IO block keeps running and delivers zeros (✅ AudioCap; same for "not yet answered"). Hence `looksLikePermissionDenied()`. `kAudioDevicePermissionsError` ('!hog') is *not* a reliable signal (⚠️).
- **Where the user grants it:**
  - macOS 15+: **System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording**, in the lower list **"System Audio Recording Only"**.
  - ⚠️ Per user reports (cava issue tracker), enabling the app only in the upper "Screen & System Audio Recording" list does not grant taps.
  - ⚠️ On macOS 14.2–14.x the exact UI location is unverified.
- **No re-prompt:** after a denial the prompt never reappears. Deep-link to the pane (§6) and ask the user to re-enable Prism, then `stop()` + `start()` the tap (relaunch if it stays silent ⚠️).
- **Ad-hoc builds:** every new build is a "new app" for TCC (§0.3). Expect stale entries in the list.
- **Optional private status probe** (same technique as AudioCap). ⚠️ Private API: it may break in any update and must never be used for the App Store. The return mapping is inferred, not documented.

```swift
import Darwin

/// ⚠️ PRIVATE TCC SPI. Inferred mapping: 0 = authorized, 1 = denied, anything else = not determined.
enum AudioCaptureTCCProbe {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32

    nonisolated(unsafe) private static let preflight: PreflightFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFn.self)
    }()

    /// nil if the SPI is unavailable.
    static func rawStatus() -> Int32? { preflight?("kTCCServiceAudioCapture" as CFString, nil) }
}
```

#### 1.2.4 Variants & gotchas

- **AudioCap-style aggregate** (real output device as the clock source). It records one app reliably but blocks in `AudioDeviceStart` until audio arrives:

  ```swift
  let outputUID = try CA.defaultOutputDeviceUID()
  let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Prism Tap",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                         kAudioSubTapUIDKey: description.uuid.uuidString]],
  ]
  ```

  The output device's own input streams (e.g. a headset mic) then also appear in the IO block's input list. `AudioMixdown` would mix them in. Prefer the tap-only aggregate.
- **Tap one app** (e.g. only Spotify): find its process object in `kAudioHardwarePropertyProcessObjectList`, matching on `kAudioProcessPropertyBundleID` ('pbid'). Then use `CATapDescription(stereoMixdownOfProcesses: [spotifyObject])`.
  - The process object exists only while the app is running.
  - On macOS 26, set `bundleIDs = ["com.spotify.client"]` and `isProcessRestoreEnabled = true` so the tap survives app relaunches (✅ header).
- **The aggregate UID must be unique.** Reusing a UID returns `'nope'` (`kAudioHardwareIllegalOperationError`).
- **Multichannel outputs:** ⚠️ the MiniMeters developer reports that while a global tap is active, output devices with more than 2 channels play at reduced (halved) volume. That report also covers ScreenCaptureKit audio since 14.2. Test with your audio interfaces.
- **Pre- or post-volume:** ⚠️ unverified whether tapped audio is independent of the system volume slider. Normalize levels adaptively (AGC) rather than relying on absolute dBFS.
- **macOS 15+ Swift wrappers:** the overlay has `AudioHardwareSystem.shared.makeProcessTap(description:)`, `makeAggregateDevice(description:)`, `AudioHardwareTap.format`, and so on (✅ `@available(macOS 15.0, *)`). This doc uses the C API so that one code path covers 14.2+.

### 1.3 ScreenCaptureKit audio, the fallback (macOS 13+)

```swift
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// System audio through ScreenCaptureKit. Requires Screen Recording permission.
public final class ScreenCaptureAudioSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum SourceError: Error {
        /// The prompt was shown, or access is denied: enable Prism in Settings, then relaunch.
        case permissionRequired
        case noDisplay
    }

    private let handler: MonoSampleHandler
    private let onStop: (@Sendable (Error?) -> Void)?
    private let scratch = ScratchBuffer(capacity: 16_384)
    private let audioQueue = DispatchQueue(label: "prism.sck.audio", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "prism.sck.video", qos: .utility)
    private let lock = NSLock()
    private var stream: SCStream?

    public init(onStop: (@Sendable (Error?) -> Void)? = nil, handler: @escaping MonoSampleHandler) {
        self.handler = handler
        self.onStop = onStop
        super.init()
    }

    public func start() async throws {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()   // shows the system prompt (first time only) and returns immediately
            throw SourceError.permissionRequired // after granting, SCK typically only works after a relaunch
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SourceError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true      // don't analyze Prism's own sounds
        config.sampleRate = 48_000
        config.channelCount = 2
        // A video stream is mandatory; make it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // 1 fps
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // Also consume .screen, otherwise SCK logs "stream output NOT found. Dropping frame" constantly.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
    }

    public func stop() async {
        let current: SCStream? = lock.withLock {
            let s = self.stream
            self.stream = nil
            return s
        }
        try? await current?.stopCapture()
    }

    // MARK: SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }   // SCK delivers Float32 (non-interleaved in practice)

        // SCK timestamps use the host-time clock (⚠️ verify); convert to mach ticks.
        let hostTime = CMClockConvertHostTimeToSystemUnits(sampleBuffer.presentationTimeStamp)
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            let frames = AudioMixdown.mono(buffers, into: scratch.pointer, capacity: scratch.capacity)
            guard frames > 0 else { return }
            handler(UnsafeBufferPointer(start: scratch.pointer, count: frames), asbd.mSampleRate, hostTime)
        }
    }

    // MARK: SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.stream = nil }
        onStop?(error)   // e.g. the user revoked permission or a display was disconnected
    }
}
```

Notes:

- ✅ APIs:
  - `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)` (async)
  - `SCContentFilter(display:excludingApplications:exceptingWindows:)`
  - `SCStreamConfiguration.capturesAudio` / `sampleRate` / `channelCount` / `excludesCurrentProcessAudio` (13.0)
  - `SCStreamOutputType.audio` (13.0)
  - `CMSampleBuffer.withAudioBufferList(blockBufferMemoryAllocator:flags:body:)`
  - `formatDescription?.audioStreamBasicDescription`
  - macOS 15 adds `captureMicrophone` and `.microphone`, which we don't need.
- **Permission:**
  - `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`. There is no usage-string key.
  - On macOS 15+ the system periodically re-asks the user to confirm continued screen-capture access. The cadence is unpublished (⚠️ weekly at 15.0, monthly later, per press reports).
  - Prefer the process tap whenever possible.
- **Alternative without TCC:** `SCContentSharingPicker` (macOS 14) lets the user pick content per session, and no Screen Recording grant is needed. This is clunky for an always-on lighting app.

### 1.4 Microphone / line-in (AVAudioEngine)

Low-latency path: `AVAudioSinkNode` (10.15). Its receiver block runs on the realtime IO thread and gets every IO cycle.
- ✅ Block type: `(UnsafePointer<AudioTimeStamp>, AVAudioFrameCount, UnsafePointer<AudioBufferList>) -> OSStatus`.
- A sink node **cannot convert formats**. Connect it with the input node's hardware format.

```swift
import AVFoundation
import AudioToolbox
import CoreAudio

public final class MicInputSource: @unchecked Sendable {
    public enum MicError: Error { case noInputDevice, deviceNotFound(String) }

    private let engine = AVAudioEngine()
    private let handler: MonoSampleHandler
    private let scratch = ScratchBuffer(capacity: 16_384)
    private let lock = NSLock()
    private var sink: AVAudioSinkNode?
    private var deviceUID: String?
    private var configObserver: NSObjectProtocol?

    public init(handler: @escaping MonoSampleHandler) { self.handler = handler }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    /// - Parameter deviceUID: Core Audio device UID (== `AVCaptureDevice.uniqueID` of a `.microphone`
    ///   device). nil = system default input.
    public func start(deviceUID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        self.deviceUID = deviceUID
        try startEngine()
        if configObserver == nil {
            // Posted when the input device or its sample rate / channel count changes; the engine has
            // already stopped itself. The notification arrives on an internal queue — hop off it.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                DispatchQueue.global(qos: .userInitiated).async { self?.restart() }
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        engine.stop()
        if let sink { engine.detach(sink) }
        sink = nil
    }

    private func restart() {
        lock.lock(); defer { lock.unlock() }
        guard sink != nil else { return }        // stopped meanwhile
        engine.stop()
        do { try startEngine() } catch { NSLog("Mic restart failed: \(error)") }
    }

    /// Call with `lock` held.
    private func startEngine() throws {
        if let uid = deviceUID { try Self.selectInputDevice(uid: uid, engine: engine) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)   // hardware format (Float32, often non-interleaved)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInputDevice }

        if let old = sink { engine.detach(old) }
        let newSink = Self.makeSink(handler: handler, scratch: scratch, sampleRate: format.sampleRate)
        engine.attach(newSink)
        engine.connect(input, to: newSink, format: format)
        sink = newSink
        engine.prepare()
        try engine.start()
    }

    /// Realtime thread: no allocation, locks, logging, or Swift concurrency inside.
    private static func makeSink(handler: @escaping MonoSampleHandler, scratch: ScratchBuffer,
                                 sampleRate: Double) -> AVAudioSinkNode {
        AVAudioSinkNode { timestamp, frameCount, inputData in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let frames = AudioMixdown.mono(buffers, into: scratch.pointer,
                                           capacity: min(scratch.capacity, Int(frameCount)))
            if frames > 0 {
                let t = timestamp.pointee
                handler(UnsafeBufferPointer(start: scratch.pointer, count: frames), sampleRate,
                        t.mFlags.contains(.hostTimeValid) ? t.mHostTime : 0)
            }
            return noErr
        }
    }

    /// Selects a specific input device. Must happen before the engine starts.
    static func selectInputDevice(uid: String, engine: AVAudioEngine) throws {
        guard var deviceID = CA.deviceID(forUID: uid) else { throw MicError.deviceNotFound(uid) }
        guard let unit = engine.inputNode.audioUnit else { throw MicError.noInputDevice }
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)),
                  "AudioUnitSetProperty(CurrentDevice)")
    }

    /// Input devices for a picker. `uniqueID` is the Core Audio device UID.
    public static func availableInputs() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                         position: .unspecified).devices
    }
}
```

Simpler but coarser alternative: a tap.
- The buffer size is a *request*. ✅ The header documents the supported range as 100–400 ms, so blocks are coarse. Use the sink node for beat-accurate lighting.

```swift
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
input.installTap(onBus: 0, bufferSize: 4_800, format: format) { buffer, _ in   // build in a nonisolated context!
    guard let channels = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    let left = UnsafeBufferPointer(start: channels[0], count: frames)
    // … analyze `left` (or average channels) …
}
try engine.start()
```

**Voice processing is for the speech mic path only.** Never use it on the music-analysis input, because it removes music by design. It gives echo cancellation, so wake-word detection survives Prism's own TTS and room music.

```swift
let input = engine.inputNode
try input.setVoiceProcessingEnabled(true)                      // engine must be stopped; throws on failure
input.voiceProcessingOtherAudioDuckingConfiguration =          // macOS 14+: don't duck the user's music
    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
// After enabling, re-read input.outputFormat(forBus: 0); the format changes (often mono).
```

⚠️ On macOS, voice processing creates a hidden aggregate with the default output device. Format and latency side effects vary by hardware, so test with USB interfaces.

---

## 2. Speech: wake word, commands, spoken confirmations

### 2.0 Choosing an engine

| | `SFSpeechRecognizer` (§2.1) | `SpeechAnalyzer` (§2.2) |
|---|---|---|
| macOS | 10.15+ (on-device). Works on every Prism target | 26.0+ |
| Permissions | Speech Recognition **and** Microphone | Microphone only. ✅ Apple: the speech-recognition authorization "applies only to SFSpeechRecognizer"; analyzer modules run on-device |
| Custom vocabulary | `contextualStrings` (≤ 100 phrases recommended) | `AnalysisContext.contextualStrings[.general]` (⚠️ effect on `SpeechTranscriber` unclear; it may only bias `DictationTranscriber`) |
| Long sessions | Restart the task periodically (~50 s) and after every final result | Designed for long-form, continuous input |
| Model management | Automatic (Siri / Dictation assets) | `AssetInventory` download per locale |

Neither framework has a true low-power keyword spotter like "Hey Siri". The wake phrase is detected by matching transcripts. Keep the mic hot only while "voice control" is enabled. The orange mic indicator is shown the whole time.

### 2.1 `WakeWordListener` (SFSpeechRecognizer, any macOS)

✅ APIs:
- `SFSpeechRecognizer(locale:)` (failable), `supportsOnDeviceRecognition`, `isAvailable`
- `queue` (an `OperationQueue`; result handlers and delegate calls run there, default `.main`)
- `SFSpeechAudioBufferRecognitionRequest`, with `requiresOnDeviceRecognition`, `shouldReportPartialResults`, `contextualStrings`, `taskHint`, `addsPunctuation` (13+), `append(_:)` and `endAudio()`
- `recognitionTask(with:resultHandler:)`, plus `cancel()` / `finish()` on the task

```swift
import AVFoundation
import Speech

/// Thread-safe holder for the *current* request: the audio tap (render thread) appends buffers,
/// the main actor swaps requests whenever the recognition task restarts.
final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newValue: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = newValue; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let current = request; lock.unlock()
        current?.append(buffer)
    }
}

/// Always-on, on-device wake-phrase listener.
/// "Hey Prism, teal on the left and brighten the key" → onCommand("teal on the left and brighten the key")
@MainActor
final class WakeWordListener: NSObject, SFSpeechRecognizerDelegate {
    enum ListenerError: Error { case recognizerUnavailable, onDeviceUnsupported, notAuthorized, noMicrophone }

    /// Text after the wake phrase (normalized, lowercase). May be "" if the user only said the wake phrase.
    var onCommand: ((String) -> Void)?
    /// Live transcript, for UI feedback.
    var onPartial: ((String) -> Void)?
    private(set) var isListening = false

    /// Fixture names, colors, etc. Biases recognition through `contextualStrings`.
    var vocabulary: [String]
    let wakePhrases: [String]

    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private let box = RecognitionRequestBox()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0                  // invalidates callbacks from cancelled tasks
    private var paused = false
    private var pendingCommand: String?
    private var maxDurationTimer: Timer?
    private var silenceTimer: Timer?
    private var errorBackoff: TimeInterval = 0.5

    private let maxTaskDuration: TimeInterval = 50     // restart long-running tasks before they degrade
    private let endOfCommandSilence: TimeInterval = 1.2

    init(locale: Locale = Locale(identifier: "en-US"),
         wakePhrases: [String] = ["hey prism", "ok prism", "okay prism"],
         vocabulary: [String] = []) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw ListenerError.recognizerUnavailable }
        // false until the on-device model for this language is present (Settings ▸ Keyboard ▸ Dictation).
        guard recognizer.supportsOnDeviceRecognition else { throw ListenerError.onDeviceUnsupported }
        self.recognizer = recognizer
        self.wakePhrases = wakePhrases.map(Self.normalize)
        self.vocabulary = vocabulary
        super.init()
        recognizer.queue = .main        // result handler + delegate on the main thread (default; made explicit)
        recognizer.delegate = self
    }

    func start() throws {
        guard !isListening else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw ListenerError.notAuthorized
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(box: box))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isListening = true
        paused = false
        startTask()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        endTask()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Stop recognizing (e.g. while Prism is talking) but keep the audio engine running.
    func pause() {
        paused = true
        endTask()
    }

    func resume() {
        guard isListening, paused else { return }
        paused = false
        startTask()
    }

    // MARK: - Task lifecycle

    /// Built outside main-actor isolation: AVAudioEngine calls the tap on its render thread.
    nonisolated private static func makeTapBlock(box: RecognitionRequestBox) -> AVAudioNodeTapBlock {
        return { buffer, _ in box.append(buffer) }
    }

    private func startTask() {
        guard isListening, !paused else { return }
        generation += 1
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true    // private, offline, and no 1-minute server limit
        request.shouldReportPartialResults = true
        request.taskHint = .search                    // short commands rather than dictation
        request.addsPunctuation = false
        request.contextualStrings = Array((["Prism", "Hey Prism"] + vocabulary).prefix(100))
        self.request = request
        box.set(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // recognizer.queue == .main, so this always runs on the main thread.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            MainActor.assumeIsolated {
                self?.handle(text: text, isFinal: isFinal, error: error, generation: gen)
            }
        }

        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxTaskDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartTask() }
        }
    }

    private func handle(text: String?, isFinal: Bool, error: Error?, generation gen: Int) {
        guard gen == generation else { return }              // stale callback from an ended task
        if let text {
            errorBackoff = 0.5
            onPartial?(text)
            if let command = Self.command(afterWakePhraseIn: text, wakePhrases: wakePhrases) {
                pendingCommand = command
                if !isFinal {
                    // Wake phrase heard: finish the utterance after a short pause in speech.
                    silenceTimer?.invalidate()
                    silenceTimer = Timer.scheduledTimer(withTimeInterval: endOfCommandSilence,
                                                        repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.finishUtterance(generation: gen) }
                    }
                }
            }
        }
        if isFinal {
            if let command = pendingCommand { onCommand?(command) }
            restartTask()                                    // fresh transcript for the next command
        } else if let error {
            // e.g. "no speech detected" after long silence (⚠️ kAFAssistantErrorDomain 1110), service hiccups,
            // SFSpeechErrorCode.timeout (12). Back off so a persistent failure can't spin.
            NSLog("Speech task ended: \(error.localizedDescription)")
            let delay = errorBackoff
            errorBackoff = min(errorBackoff * 2, 8)
            endTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.startTask() }
            }
        }
    }

    /// Stop feeding audio so the recognizer produces a final result for the command.
    private func finishUtterance(generation gen: Int) {
        guard gen == generation else { return }
        box.set(nil)
        request?.endAudio()
    }

    private func restartTask() {
        endTask()
        startTask()
    }

    private func endTask() {
        generation += 1
        maxDurationTimer?.invalidate(); maxDurationTimer = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        pendingCommand = nil
        box.set(nil)
        request?.endAudio()
        request = nil
        task?.cancel()       // its error callback is ignored thanks to `generation`
        task = nil
    }

    // MARK: - SFSpeechRecognizerDelegate

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isListening, !self.paused else { return }
            if available { self.restartTask() } else { self.endTask() }
        }
    }

    // MARK: - Wake phrase matching

    /// Words after the *last* wake phrase, or nil if no wake phrase occurs (whole-word match).
    nonisolated static func command(afterWakePhraseIn transcript: String, wakePhrases: [String]) -> String? {
        let padded = " " + normalize(transcript) + " "
        var best: Range<String.Index>?
        for phrase in wakePhrases {
            guard let range = padded.range(of: " \(phrase) ", options: .backwards) else { continue }
            if best == nil || range.lowerBound > best!.lowerBound { best = range }
        }
        guard let match = best else { return nil }
        return String(padded[match.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// "Hey, Prism!" → "hey prism". Lowercases, strips diacritics and punctuation, collapses spaces.
    nonisolated static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}
```

Notes:

- **Restart policy.** The engine and tap stay up. Only the request and task are replaced:
  - after every final result,
  - after an error (with backoff),
  - and every ~50 s.
  The `generation` counter makes stale callbacks harmless, because `cancel()` triggers an error callback later.
- **Misrecognitions.** Add aliases the recognizer actually produces ("hey prisma", "hey prison", "a prism"). Log `onPartial` output during testing to collect them.
- **Pause around TTS** (§2.3): `speaker.onSpeakingChanged = { $0 ? listener.pause() : listener.resume() }`.
- **Hand the command to the interpreter.** Pass the command to §3 (on-device LLM) and §4 (cloud), with a rule-based parser as the last resort.
- **Error domains.** `SFSpeechErrorDomain` codes are public (✅ `SFErrors.h`, macOS 14):
  - 1 internalServiceError
  - 2 audioReadFailed
  - 7 undefinedTemplateClassName
  - 8 malformedSupplementalModel
  - 12 timeout
  - 13 missingParameter
  The common runtime errors come from the private `kAFAssistantErrorDomain` (⚠️ observed codes: 1110 "no speech detected", 216/301 "request canceled"). Never switch on those for correctness; just restart.

Authorization must be requested from a non-isolated context. The handler is called on an arbitrary queue: ✅ the header states it "does not use" `recognizer.queue`.

```swift
import AVFoundation
import Speech

enum SpeechPermissions {
    static func requestSpeechRecognition() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            // Explicitly @Sendable ⇒ never main-actor-isolated, even if called from @MainActor code.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
```

### 2.2 `ModernTranscriber` (SpeechAnalyzer, macOS 26+)

✅ API (26.5 swiftinterface):

- **`SpeechAnalyzer`** is an `actor`.
  - Setup: `init(modules:options:)`, `prepareToAnalyze(in:)`, `setContext(_:)`.
  - Input: `start(inputSequence:)`, where `Element == AnalyzerInput`. It returns once analysis is running.
  - Shutdown: `finalizeAndFinishThroughEndOfInput()`, `cancelAndFinishNow()`.
  - Format: `static bestAvailableAudioFormat(compatibleWith:) async -> AVAudioFormat?`.
  - Options: `Options(priority:modelRetention:)`, where `modelRetention` is `.whileInUse`, `.lingering` or `.processLifetime`.
- **`AnalyzerInput(buffer:)`** and `AnalyzerInput(buffer:bufferStartTime:)`.
- **`SpeechTranscriber`**
  - `init(locale:preset:)`, where `Preset` is `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription` or `.timeIndexedProgressiveTranscription`.
  - `static isAvailable`, `static supportedLocale(equivalentTo:) async`, `supportedLocales`, `installedLocales`.
  - `results`: an async sequence of `Result` (`text: AttributedString`, `alternatives`, `range`, `isFinal`).
- **`DictationTranscriber`** (the fallback when `SpeechTranscriber.isAvailable == false`).
  - `init(locale:preset:)`, where `Preset` is `.phrase`, `.shortDictation`, `.progressiveShortDictation`, `.longDictation`, `.progressiveLongDictation` or `.timeIndexedLongDictation`.
  - `ContentHint` is `.shortForm`, `.farField` or `.atypicalSpeech`. Use it through the long initializer.
- **`AssetInventory`**
  - `status(forModules:)`, returning `.unsupported`, `.supported`, `.downloading` or `.installed`.
  - `assetInstallationRequest(supporting:) async throws -> AssetInstallationRequest?`, which has `progress` and `downloadAndInstall()`.
  - `reserve(locale:)` / `release(reservedLocale:)`.
- **`AnalysisContext`**: `contextualStrings[.general]`.
- **`SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)`**: voice-activity gating, added as an extra module next to a transcriber.

```swift
#if canImport(Speech)
import AVFoundation
import Speech

@available(macOS 26.0, *)
@MainActor
final class ModernTranscriber {
    enum TranscriberError: Error { case localeNotSupported(Locale), noAudioFormat, noMicrophone, converterUnavailable }

    /// (text, isFinal). Volatile results (isFinal == false) are superseded by later results for the same audio.
    var onResult: ((String, Bool) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    func start(locale: Locale = Locale(identifier: "en-US"), contextualStrings: [String] = []) async throws {
        await stop()
        do {
            try await startPipeline(locale: locale, contextualStrings: contextualStrings)
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()                 // end of input…
        continuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()   // …then flush final results
        }
        analyzer = nil
        resultsTask = nil                      // its loop ends when the results sequence finishes
    }

    private func startPipeline(locale: Locale, contextualStrings: [String]) async throws {
        // 1. Module: SpeechTranscriber (new long-form model) where available, else DictationTranscriber.
        let module: any SpeechModule
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            module = transcriber
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.onResult?(String(result.text.characters), result.isFinal)
                    }
                } catch {
                    NSLog("SpeechTranscriber results failed: \(error)")
                }
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
            module = transcriber
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.onResult?(String(result.text.characters), result.isFinal)
                    }
                } catch {
                    NSLog("DictationTranscriber results failed: \(error)")
                }
            }
        } else {
            throw TranscriberError.localeNotSupported(locale)
        }
        let modules: [any SpeechModule] = [module]

        // 2. Ensure the on-device model for this locale is installed (one-time download).
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            // installation.progress is a Foundation.Progress you can show in the UI.
            try await installation.downloadAndInstall()
        }

        // 3. Formats: the analyzer's preferred format vs. the mic's hardware format.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw TranscriberError.noAudioFormat
        }
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw TranscriberError.noMicrophone }
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw TranscriberError.converterUnavailable
        }

        // 4. Analyzer fed by an AsyncStream.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: modules,
                                      options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings   // ⚠️ may only bias DictationTranscriber
            try await analyzer.setContext(context)
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.continuation = continuation

        // 5. Microphone → converter → stream.
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat,
                         block: Self.makeTapBlock(converter: converter, format: analyzerFormat,
                                                  continuation: continuation))
        engine.prepare()
        try engine.start()
    }

    /// Runs on the render thread; built in a nonisolated context.
    nonisolated private static func makeTapBlock(converter: AVAudioConverter, format: AVAudioFormat,
                                                 continuation: AsyncStream<AnalyzerInput>.Continuation)
        -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let converted = convert(buffer, using: converter, to: format) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Streams one buffer through a persistent converter. `.noDataNow` (not `.endOfStream`) keeps the
    /// resampler state valid between calls. The output is a fresh buffer, safe to hand off.
    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                    to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let feed = ConverterFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = feed.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// One-shot holder used inside AVAudioConverter's input block. That block type is NS_SWIFT_SENDABLE,
/// so it may not mutate captured local vars; it is called synchronously within convert(to:error:withInputFrom:).
final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
#endif
```

Wake word on macOS 26:
- Feed `onResult` text into the same `WakeWordListener.command(afterWakePhraseIn:wakePhrases:)` matcher.
- With `.progressiveTranscription`, the volatile results arrive quickly. Act on the final result, or after ~1 s with no change.
- Unlike `SFSpeechRecognizer`, there's no need to restart sessions periodically.

Choosing at runtime:

```swift
if #available(macOS 26.0, *) {
    let transcriber = ModernTranscriber()
    transcriber.onResult = { text, isFinal in /* wake-phrase matching */ }
    try await transcriber.start(contextualStrings: ["Prism", "key light", "fill", "backlight"])
} else {
    let listener = try WakeWordListener(vocabulary: ["key light", "fill", "backlight"])
    try listener.start()
}
```

### 2.3 `Speaker` (AVSpeechSynthesizer)

```swift
import AVFoundation

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    /// true while speaking — pause the wake-word listener and gate audio analysis meanwhile.
    var onSpeakingChanged: ((Bool) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()        // must be retained for speech to continue
    private var continuations: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks and returns when the utterance finished or was cancelled.
    func say(_ text: String, voiceIdentifier: String? = nil, rate: Float = AVSpeechUtteranceDefaultSpeechRate) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            continuations[ObjectIdentifier(utterance)] = continuation
            if continuations.count == 1 { onSpeakingChanged?(true) }
            synthesizer.speak(utterance)
        }
    }

    func stopSpeaking() { synthesizer.stopSpeaking(at: .immediate) }

    /// Best installed English voices first (enhanced/premium voices are downloaded in System Settings ▸ Accessibility ▸ Spoken Content).
    static func preferredVoices(language: String = "en") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    // The delegate protocol is NS_SWIFT_SENDABLE and non-isolated: hop to the main actor explicitly.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    private func finish(_ id: ObjectIdentifier) {
        continuations.removeValue(forKey: id)?.resume()
        if continuations.isEmpty { onSpeakingChanged?(false) }
    }
}
```

Notes:
- **Volume and pitch.** `AVSpeechUtterance` also has `pitchMultiplier` (0.5–2.0) and `volume` (0–1).
- **Voice quality.** `AVSpeechSynthesisVoiceQuality` is `.default`, `.enhanced` or `.premium`.
- **Echo into analysis.** TTS output reaches the system-audio tap unless that output comes from Prism's own (excluded) process. ⚠️ It may be rendered by a system speech process, so pause audio-reactive analysis while `onSpeakingChanged(true)`.
- **Echo into the mic.** For a mic-based wake word during playback, enable voice processing on the *speech* engine (§1.4), or simply pause recognition while speaking.

---
