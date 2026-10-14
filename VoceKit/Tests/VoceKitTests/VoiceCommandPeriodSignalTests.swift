import Foundation
import Testing
@testable import VoceKit

private func service() -> VoiceCommandService {
    VoiceCommandService(commands: VoiceCommand.builtIns)
}

@Test(
    "Period/colon convert after adjectives, ordinals and names at strong signals",
    arguments: [
        ("That sounds good period", "That sounds good."),
        ("I feel great period", "I feel great."),
        ("Not bad period", "Not bad."),
        ("You're next period", "You're next."),
        ("I came first period", "I came first."),
        ("That was amazing period", "That was amazing."),
        ("I'm so happy period", "I'm so happy."),
        ("Take it slow period", "Take it slow."),
        ("Wait a second period", "Wait a second."),
        ("Stay calm period", "Stay calm."),
        ("See you next period", "See you next."),
        ("That was great period", "That was great."),
        ("Sounds good period Talk soon", "Sounds good. Talk soon"),
        ("I feel good period I will call", "I feel good. I will call"),
        ("I met Sarah period She was nice", "I met Sarah. She was nice"),
        ("I talked to Bob period Then I left", "I talked to Bob. Then I left"),
        ("We met in March period It was cold", "We met in March. It was cold"),
        ("The meeting is on Monday period Please attend", "The meeting is on Monday. Please attend"),
        ("I live in New York period It is busy", "I live in New York. It is busy"),
        ("We use Slack period It works", "We use Slack. It works"),
        ("Hi Bob colon Please review", "Hi Bob: Please review"),
        ("Dear Sarah colon Please review", "Dear Sarah: Please review"),
        ("Call me period. Thanks period.", "Call me. Thanks."),
        ("I'm done period, see you", "I'm done, see you"),
        ("Thanks period. Bye period.", "Thanks. Bye."),
    ]
)
func periodColonConvertAtStrongSignals(input: String, expected: String) {
    #expect(service().apply(to: input) == expected)
}

@Test(
    "Prose with period/colon nouns stays unchanged",
    arguments: [
        "Each period, the teacher checks.",
        "The Jurassic period, which lasted millions of years, ended.",
        "During the Edo period, Japan grew.",
        "In fifth period, I have math.",
        "My favorite period, honestly, was summer.",
        "That was a great period. We grew.",
        "The trial period ended yesterday.",
        "There is not enough space on the disk.",
        "He had a colon procedure.",
        "Please delete that file from the server.",
        "Done period? Really",
        "Call me period! Now",
    ]
)
func periodColonProseUnchanged(sentence: String) {
    #expect(service().apply(to: sentence) == sentence)
}

/// Triggers are judged from a bounded window around each match, falling back
/// to the full text when the window can't decide; long prefixes must not
/// change the outcome.
@Test(
    "Long text before a command doesn't change how it is judged",
    arguments: [
        String(repeating: "we talked about the plan for a while ", count: 40) + "and agreed. ",
        String(repeating: "x", count: 600) + ". ",
    ]
)
func longPrefixDoesNotChangeCommandOutcome(prefix: String) {
    let cases = [
        ("That sounds good period", "That sounds good."),
        ("I talked to Bob period Then I left", "I talked to Bob. Then I left"),
        ("Hi Bob colon Please review", "Hi Bob: Please review"),
        ("Call me period. Thanks period.", "Call me. Thanks."),
        ("The trial period ended yesterday.", "The trial period ended yesterday."),
        ("During the Edo period, Japan grew.", "During the Edo period, Japan grew."),
    ]
    for (input, expected) in cases {
        #expect(service().apply(to: prefix + input) == prefix + expected)
    }
}

@Test("A command after a long run of spaces is still judged from the text before it")
func commandAfterLongWhitespace() {
    let input = "Okay." + String(repeating: " ", count: 400) + "That sounds good period"
    #expect(service().apply(to: input) == "Okay. That sounds good.")
}

@Test("A deletion question after a long run of spaces stays a question")
func deletionQuestionAfterLongWhitespace() {
    let input = "Can you delete that" + String(repeating: " ", count: 300) + "?"
    #expect(service().apply(to: input) == input)
}
