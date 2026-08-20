import Foundation
import AVFoundation

@Observable
class SpeechStory: Identifiable {
    typealias StartTime = CMTime
    
    let id: UUID
    var title: String
    var text: AttributedString
    var url: URL?
    var isDone: Bool
    
    init(title: String = "Transcript", text: AttributedString = AttributedString(""), url: URL? = nil, isDone: Bool = false) {
        self.title = title
        self.text = text
        self.url = url
        self.isDone = isDone
        self.id = UUID()
    }
    
    static func blank() -> SpeechStory {
        return .init(title: "Transcript", text: AttributedString(""))
    }
    
    func storyBrokenUpByLines() -> AttributedString {
        if url == nil {
            return text
        } else {
            var final = AttributedString("")
            var working = AttributedString("")
            let copy = text
            copy.runs.forEach { run in
                if copy[run.range].characters.contains(".") {
                    working.append(copy[run.range])
                    final.append(working)
                    final.append(AttributedString("\n\n"))
                    working = AttributedString("")
                } else {
                    if working.characters.isEmpty {
                        let newText = copy[run.range].characters
                        let attributes = run.attributes
                        let trimmed = newText.trimmingPrefix(" ")
                        let newAttributed = AttributedString(trimmed, attributes: attributes)
                        working.append(newAttributed)
                    } else {
                        working.append(copy[run.range])
                    }
                }
            }
            
            if final.characters.isEmpty {
                return working
            }
            
            return final
        }
    }
}
