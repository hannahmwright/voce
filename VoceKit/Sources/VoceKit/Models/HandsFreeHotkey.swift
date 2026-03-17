import Foundation

public enum HandsFreeHotkey: Codable, Sendable, Equatable {
    case keyCode(UInt16)
    case modifier(Modifier)

    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case option
        case control
        case command
        case shift
        case function

        public var displayName: String {
            switch self {
            case .option: return "Option"
            case .control: return "Control"
            case .command: return "Command"
            case .shift: return "Shift"
            case .function: return "Globe/Fn"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case keyCode
        case modifier
    }

    private enum Kind: String, Codable {
        case keyCode
        case modifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .keyCode:
            self = .keyCode(try container.decode(UInt16.self, forKey: .keyCode))
        case .modifier:
            self = .modifier(try container.decode(Modifier.self, forKey: .modifier))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .keyCode(let keyCode):
            try container.encode(Kind.keyCode, forKey: .kind)
            try container.encode(keyCode, forKey: .keyCode)
        case .modifier(let modifier):
            try container.encode(Kind.modifier, forKey: .kind)
            try container.encode(modifier, forKey: .modifier)
        }
    }
}
