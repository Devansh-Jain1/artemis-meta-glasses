import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages silent audio playback to keep the app alive in background.
/// Enable "Audio, AirPlay, and Picture in Picture" in Background Modes capability.
public final class BackgroundAudioManager: NSObject {
    
    public static let shared = BackgroundAudioManager()
    
    private var audioPlayer: AVAudioPlayer?
    private var isRunning = false
    
    private override init() {
        super.init()
        setupAudioSession()
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // PlayAndRecord allows mic input + speaker output
            try session.setCategory(.playAndRecord, mode: .default, options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .mixWithOthers
            ])
            try session.setActive(true)
        } catch {
            print("[BackgroundAudioManager] Failed to configure audio session: \(error)")
        }
        #endif
    }
    
    // MARK: - Start/Stop Background Task
    
    /// Start playing silent audio to keep app alive in background.
    public func start() {
        guard !isRunning else { return }
        
        // Generate a tiny silent audio buffer
        guard let silentURL = createSilentAudioFile() else {
            print("[BackgroundAudioManager] Could not create silent audio file")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: silentURL)
            audioPlayer?.numberOfLoops = -1 // Loop forever
            audioPlayer?.volume = 0.01 // Nearly silent
            audioPlayer?.play()
            isRunning = true
            print("[BackgroundAudioManager] Started background audio keepalive")
        } catch {
            print("[BackgroundAudioManager] Failed to start audio player: \(error)")
        }
    }
    
    /// Stop the background audio keepalive.
    public func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isRunning = false
        print("[BackgroundAudioManager] Stopped background audio keepalive")
    }
    
    // MARK: - Silent Audio Generation
    
    private func createSilentAudioFile() -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("silence.wav")
        
        // If already exists, reuse it
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        
        // Create a minimal WAV file (44 bytes header + 1 second of silence at 8kHz mono 8-bit)
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 8
        let duration: UInt32 = 1 // 1 second
        let dataSize = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8) * duration
        let fileSize = 36 + dataSize
        
        var header = Data()
        
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        
        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // AudioFormat (PCM)
        header.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = numChannels * (bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        
        // data subchunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        
        // Silent samples (128 = silence for unsigned 8-bit PCM)
        let silentData = Data(repeating: 128, count: Int(dataSize))
        header.append(silentData)
        
        do {
            try header.write(to: fileURL)
            return fileURL
        } catch {
            print("[BackgroundAudioManager] Failed to write silent audio: \(error)")
            return nil
        }
    }
}
