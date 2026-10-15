import Foundation

// MARK: - Tool Definitions

/// Available tools that Artemis can call
enum ArtemisToolType: String, CaseIterable {
    case getCurrentTime = "get_current_time"
    case getCurrentDate = "get_current_date"
    case setReminder = "set_reminder"
    case getWeather = "get_weather"
    case calculate = "calculate"
    case saveNote = "save_note"
    case getNotes = "get_notes"
}

/// Tool call request parsed from LLM output
struct ToolCall {
    let tool: ArtemisToolType
    let parameters: [String: String]
}

/// Tool execution result
struct ToolResult {
    let success: Bool
    let output: String
}

// MARK: - Tool Executor

@MainActor
class ToolExecutor {
    static let shared = ToolExecutor()
    
    // Simple in-memory storage for notes and reminders
    private var notes: [String] = []
    private var reminders: [(text: String, time: Date?)] = []
    
    private init() {}
    
    /// Execute a tool and return the result
    func execute(tool: ArtemisToolType, parameters: [String: String]) -> ToolResult {
        switch tool {
        case .getCurrentTime:
            return getCurrentTime()
        case .getCurrentDate:
            return getCurrentDate()
        case .setReminder:
            return setReminder(text: parameters["text"] ?? "", time: parameters["time"])
        case .getWeather:
            return getWeather(location: parameters["location"])
        case .calculate:
            return calculate(expression: parameters["expression"] ?? "")
        case .saveNote:
            return saveNote(content: parameters["content"] ?? "")
        case .getNotes:
            return getNotes()
        }
    }
    
    // MARK: - Tool Implementations
    
    private func getCurrentTime() -> ToolResult {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let time = formatter.string(from: Date())
        return ToolResult(success: true, output: "The current time is \(time)")
    }
    
    private func getCurrentDate() -> ToolResult {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        let date = formatter.string(from: Date())
        return ToolResult(success: true, output: "Today is \(date)")
    }
    
    private func setReminder(text: String, time: String?) -> ToolResult {
        guard !text.isEmpty else {
            return ToolResult(success: false, output: "I need to know what to remind you about.")
        }
        
        // Parse time if provided (simple implementation)
        var reminderTime: Date? = nil
        if let timeStr = time {
            // Simple parsing for "in X minutes" or "at HH:MM"
            if timeStr.contains("minute") {
                if let minutes = Int(timeStr.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) {
                    reminderTime = Date().addingTimeInterval(Double(minutes) * 60)
                }
            }
        }
        
        reminders.append((text: text, time: reminderTime))
        
        if let time = reminderTime {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return ToolResult(success: true, output: "I've set a reminder for \(formatter.string(from: time)): \(text)")
        } else {
            return ToolResult(success: true, output: "I've noted your reminder: \(text)")
        }
    }
    
    private func getWeather(location: String?) -> ToolResult {
        // Placeholder - would need actual weather API
        let loc = location ?? "your location"
        return ToolResult(success: true, output: "I don't have access to weather data yet, but I can help you check the weather for \(loc) once connected.")
    }
    
    private func calculate(expression: String) -> ToolResult {
        guard !expression.isEmpty else {
            return ToolResult(success: false, output: "I need a math expression to calculate.")
        }
        
        // Simple NSExpression evaluation
        let cleanExpr = expression
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
        
        let expr = NSExpression(format: cleanExpr)
        if let result = expr.expressionValue(with: nil, context: nil) as? NSNumber {
            return ToolResult(success: true, output: "\(expression) equals \(result)")
        }

        return ToolResult(success: false, output: "I couldn't calculate that expression.")
    }
    
    private func saveNote(content: String) -> ToolResult {
        guard !content.isEmpty else {
            return ToolResult(success: false, output: "I need some content to save as a note.")
        }
        
        notes.append(content)
        return ToolResult(success: true, output: "I've saved your note: \(content.prefix(50))...")
    }
    
    private func getNotes() -> ToolResult {
        if notes.isEmpty {
            return ToolResult(success: true, output: "You don't have any saved notes yet.")
        }
        
        let noteList = notes.enumerated().map { "\($0.offset + 1). \($0.element.prefix(30))..." }.joined(separator: ", ")
        return ToolResult(success: true, output: "You have \(notes.count) notes: \(noteList)")
    }
    
    // MARK: - Clear Data
    
    func clearAll() {
        notes.removeAll()
        reminders.removeAll()
    }
}

// MARK: - Tool Detection

/// Detects if user input requires a tool call
class ToolDetector {
    
    /// Keywords that suggest tool usage (order matters - more specific patterns first)
    private static let toolPatterns: [(pattern: String, tool: ArtemisToolType)] = [
        // Time (specific patterns first)
        ("what time is it", .getCurrentTime),
        ("what's the time", .getCurrentTime),
        ("what time", .getCurrentTime),
        ("current time", .getCurrentTime),
        ("tell me the time", .getCurrentTime),
        
        // Date (specific patterns first - before generic "what is")
        ("what is today's date", .getCurrentDate),
        ("what's today's date", .getCurrentDate),
        ("today's date", .getCurrentDate),
        ("what is today", .getCurrentDate),
        ("what's today", .getCurrentDate),
        ("what date is it", .getCurrentDate),
        ("what day is it", .getCurrentDate),
        ("what date", .getCurrentDate),
        ("what day", .getCurrentDate),
        
        // Reminders
        ("remind me", .setReminder),
        ("set a reminder", .setReminder),
        ("reminder for", .setReminder),
        ("don't let me forget", .setReminder),
        
        // Weather
        ("weather", .getWeather),
        ("temperature", .getWeather),
        ("forecast", .getWeather),
        
        // Calculate (generic patterns last)
        ("calculate", .calculate),
        ("how much is", .calculate),
        ("plus", .calculate),
        ("minus", .calculate),
        ("times", .calculate),
        ("divided by", .calculate),
        ("multiply", .calculate),
        
        // Notes
        ("save a note", .saveNote),
        ("note this", .saveNote),
        ("remember this", .saveNote),
        ("my notes", .getNotes),
        ("show notes", .getNotes),
        ("what are my notes", .getNotes),
    ]
    
    /// Detect if input matches a tool pattern
    static func detectTool(input: String) -> (tool: ArtemisToolType, parameters: [String: String])? {
        let lowercased = input.lowercased()
        
        for (pattern, tool) in toolPatterns {
            if lowercased.contains(pattern) {
                let params = extractParameters(input: input, tool: tool)
                return (tool, params)
            }
        }
        
        return nil
    }
    
    /// Extract parameters from input based on tool type
    private static func extractParameters(input: String, tool: ArtemisToolType) -> [String: String] {
        var params: [String: String] = [:]
        
        switch tool {
        case .setReminder:
            // Extract reminder text after "remind me to" or similar
            if let range = input.range(of: "remind me to ", options: .caseInsensitive) {
                params["text"] = String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let range = input.range(of: "remind me ", options: .caseInsensitive) {
                params["text"] = String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            
        case .calculate:
            // Extract math expression
            let mathPattern = try? NSRegularExpression(pattern: "[\\d\\s\\+\\-\\*\\/\\(\\)x×÷]+", options: [])
            if let match = mathPattern?.firstMatch(in: input, options: [], range: NSRange(input.startIndex..., in: input)) {
                if let range = Range(match.range, in: input) {
                    params["expression"] = String(input[range]).trimmingCharacters(in: .whitespaces)
                }
            }
            
        case .saveNote:
            // Extract note content
            if let range = input.range(of: "note ", options: .caseInsensitive) {
                params["content"] = String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let range = input.range(of: "remember ", options: .caseInsensitive) {
                params["content"] = String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            
        case .getWeather:
            // Extract location if mentioned
            if let range = input.range(of: "in ", options: .caseInsensitive) {
                params["location"] = String(input[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            
        default:
            break
        }
        
        return params
    }
}
