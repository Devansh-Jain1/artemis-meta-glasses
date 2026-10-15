import Foundation
import AVFoundation

// MARK: - Turn-Taking State Machine
/// Manages conversation state transitions for natural turn-taking
/// Handles: listening, processing, speaking, and barge-in states
/// Note: Uses TurnState to avoid conflict with TurnState in ArtemisApp.swift

public enum TurnState: String {
    case idle           = "IDLE"           // Not in conversation
    case listening      = "LISTENING"      // VAD active, waiting for speech
    case userSpeaking   = "USER_SPEAKING"  // User is currently talking
    case processing     = "PROCESSING"     // Processing user input (STT/LLM)
    case agentSpeaking  = "AGENT_SPEAKING" // TTS is playing
    case bargeIn        = "BARGE_IN"       // User interrupted agent
}

public protocol TurnTakingDelegate: AnyObject {
    func turnTakingDidChangeState(from: TurnState, to: TurnState)
    func turnTakingDidDetectBargeIn(transcribedText: String)
    func turnTakingDidCompleteTurn(userText: String)
    func turnTakingDidTimeoutProcessing(afterMilliseconds milliseconds: Double)
    func turnTakingShouldStartListening()
    func turnTakingShouldStopTTS()
}

public final class TurnTakingManager {
    
    public static let shared = TurnTakingManager()
    
    // MARK: - Properties
    
    public weak var delegate: TurnTakingDelegate?
    
    public private(set) var currentState: TurnState = .idle {
        didSet {
            if oldValue != currentState {
                print("[TurnTaking] State: \(oldValue.rawValue) → \(currentState.rawValue)")
                delegate?.turnTakingDidChangeState(from: oldValue, to: currentState)
            }
        }
    }
    
    // MARK: - Timing Configuration
    
    private struct Timing {
        static let endOfTurnSilenceMs: Double = 800    // Silence before considering turn complete
        static let bargeInDelayMs: Double = 300        // Min speech duration to trigger barge-in
        static let postTTSListenDelayMs: Double = 200  // Delay before listening after TTS
        static let maxProcessingTimeMs: Double = 30000 // Slow-turn warning threshold
    }
    
    // MARK: - State
    
    private var speechStartTime: Date?
    private var silenceStartTime: Date?
    private var processingStartTime: Date?
    private var lastUserTranscript: String = ""
    
    // Timers
    private var endOfTurnTimer: Timer?
    private var processingTimeoutTimer: Timer?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - State Transitions
    
    /// Start a new conversation session
    public func startConversation() {
        guard currentState == .idle else { return }
        transitionTo(.listening)
        delegate?.turnTakingShouldStartListening()
    }
    
    /// End the conversation session
    public func endConversation() {
        cancelAllTimers()
        transitionTo(.idle)
    }
    
    /// Called when VAD detects speech start
    public func onSpeechStart() {
        speechStartTime = Date()
        silenceStartTime = nil
        cancelEndOfTurnTimer()
        
        switch currentState {
        case .listening:
            transitionTo(.userSpeaking)
            
        case .agentSpeaking:
            // Potential barge-in - but don't transition yet
            // Wait for actual transcript to verify it's not echo
            print("[TurnTaking] Speech during agent speaking - potential barge-in")
            
        case .userSpeaking:
            // Already speaking, ignore
            break
            
        default:
            print("[TurnTaking] Unexpected speech start in state: \(currentState.rawValue)")
        }
    }
    
    /// Called when VAD detects speech end
    public func onSpeechEnd() {
        silenceStartTime = Date()
        
        switch currentState {
        case .userSpeaking:
            // Start end-of-turn timer
            startEndOfTurnTimer()
            
        case .agentSpeaking:
            // Speech ended during TTS - probably echo finishing
            print("[TurnTaking] Speech ended during TTS (likely echo)")
            
        default:
            break
        }
    }
    
    /// Called when STT produces a transcript
    public func onTranscript(_ text: String, isFinal: Bool) {
        lastUserTranscript = text
        
        switch currentState {
        case .userSpeaking:
            if isFinal {
                // User finished speaking
                cancelEndOfTurnTimer()
                handleTurnComplete(userText: text)
            }
            
        case .agentSpeaking:
            // Check if this is a valid barge-in
            let bargeInResult = EchoDetector.shared.isValidBargeIn(transcribedText: text)

            if bargeInResult.isValid {
                print("[TurnTaking] ✅ Valid barge-in: \(bargeInResult.reason)")
                handleBargeIn(text: text)
                if isFinal {
                    handleTurnComplete(userText: text)
                }
            } else {
                print("[TurnTaking] ❌ Rejected as echo: \(bargeInResult.reason)")
            }
            
        case .listening:
            // Got transcript while listening - user started speaking
            transitionTo(.userSpeaking)
            if isFinal {
                handleTurnComplete(userText: text)
            }
            
        default:
            break
        }
    }
    
    /// Called when LLM processing starts
    public func onProcessingStart() {
        transitionTo(.processing)
        processingStartTime = Date()
        startProcessingTimeoutTimer()
    }
    
    /// Called when LLM processing completes
    public func onProcessingComplete() {
        cancelProcessingTimeoutTimer()
        // Will transition to agentSpeaking when TTS starts
    }
    
    /// Called when TTS starts speaking
    public func onTTSStart(text: String) {
        EchoDetector.shared.ttsDidStart(text: text)
        transitionTo(.agentSpeaking)
    }
    
    /// Called when TTS finishes speaking
    public func onTTSEnd() {
        EchoDetector.shared.ttsDidEnd()
        
        // Small delay before transitioning to listening
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.postTTSListenDelayMs / 1000) { [weak self] in
            guard let self = self, self.currentState == .agentSpeaking else { return }
            self.transitionTo(.listening)
            self.delegate?.turnTakingShouldStartListening()
        }
    }
    
    // MARK: - Private Methods
    
    private func transitionTo(_ newState: TurnState) {
        currentState = newState
    }
    
    private func handleTurnComplete(userText: String) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("[TurnTaking] Ignoring empty turn completion.")
            transitionTo(.listening)
            return
        }
        print("[TurnTaking] Turn complete: \"\(trimmed.prefix(50))...\"")
        transitionTo(.processing)
        delegate?.turnTakingDidCompleteTurn(userText: trimmed)
    }
    
    private func handleBargeIn(text: String) {
        // Stop TTS
        delegate?.turnTakingShouldStopTTS()
        
        // Transition to barge-in then user speaking
        transitionTo(.bargeIn)
        delegate?.turnTakingDidDetectBargeIn(transcribedText: text)
        
        // Immediately transition to user speaking
        transitionTo(.userSpeaking)
    }
    
    // MARK: - Timers
    
    private func startEndOfTurnTimer() {
        cancelEndOfTurnTimer()
        endOfTurnTimer = Timer.scheduledTimer(withTimeInterval: Timing.endOfTurnSilenceMs / 1000, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.currentState == .userSpeaking {
                self.handleTurnComplete(userText: self.lastUserTranscript)
            }
        }
    }
    
    private func cancelEndOfTurnTimer() {
        endOfTurnTimer?.invalidate()
        endOfTurnTimer = nil
    }
    
    private func startProcessingTimeoutTimer() {
        cancelProcessingTimeoutTimer()
        processingTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Timing.maxProcessingTimeMs / 1000, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.currentState == .processing {
                print("[TurnTaking] ⚠️ Processing slow - waiting for brain result")
                self.delegate?.turnTakingDidTimeoutProcessing(afterMilliseconds: Timing.maxProcessingTimeMs)
            }
        }
    }
    
    private func cancelProcessingTimeoutTimer() {
        processingTimeoutTimer?.invalidate()
        processingTimeoutTimer = nil
    }
    
    private func cancelAllTimers() {
        cancelEndOfTurnTimer()
        cancelProcessingTimeoutTimer()
    }
    
    // MARK: - Debug
    
    public func getStateDescription() -> String {
        var desc = "State: \(currentState.rawValue)"
        if let speechStart = speechStartTime {
            desc += ", Speaking for: \(String(format: "%.1f", Date().timeIntervalSince(speechStart)))s"
        }
        if let silenceStart = silenceStartTime {
            desc += ", Silent for: \(String(format: "%.1f", Date().timeIntervalSince(silenceStart)))s"
        }
        return desc
    }
    
    // MARK: - Reset
    
    public func reset() {
        cancelAllTimers()
        currentState = .idle
        speechStartTime = nil
        silenceStartTime = nil
        processingStartTime = nil
        lastUserTranscript = ""
        EchoDetector.shared.reset()
        print("[TurnTaking] Reset")
    }
}
