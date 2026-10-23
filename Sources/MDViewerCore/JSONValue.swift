import Foundation

/// Any JSON value. Claude Code's messages carry tool inputs of every shape: the
/// chat reads a few fields from them and hands them back unchanged.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        switch self {
        case .object(let object): object[key]
        default: nil
        }
    }

    public subscript(index: Int) -> JSONValue? {
        switch self {
        case .array(let array) where array.indices.contains(index): array[index]
        default: nil
        }
    }

    public var string: String? {
        switch self {
        case .string(let value): value
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        default: nil
        }
    }

    public var number: Double? {
        switch self {
        case .number(let value): value
        default: nil
        }
    }

    public var array: [JSONValue]? {
        switch self {
        case .array(let value): value
        default: nil
        }
    }

    /// The value as one line of JSON text, ending with a line break.
    public var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a JSONValue can't fail: every case maps to plain JSON.
        var data = (try? encoder.encode(self)) ?? Data("null".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// Literals, so messages can be written the way they look on the wire.
extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
