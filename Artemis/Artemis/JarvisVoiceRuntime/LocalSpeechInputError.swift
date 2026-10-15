import Foundation

enum LocalSpeechInputError: LocalizedError {
    case alreadyStarting

    var errorDescription: String? {
        "Speech input is already starting."
    }
}
