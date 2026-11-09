import Foundation

public struct ToolValidationError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// Validates a tool call's arguments against the tool's JSON Schema, coercing first the way models need: `"42"` for
/// a number, `"true"` for a boolean, a single value for an array, and `null` for an omitted optional property.
///
/// Supports the schema keywords tools use: `type` (one or a list), `properties`, `required`, `items`, `enum`,
/// `const`, `anyOf`/`oneOf`, `minimum`/`maximum`, `minLength`/`maxLength`, `minItems`/`maxItems` and
/// `additionalProperties: false`.
public func validateToolArguments(tool: Tool, toolCall: ToolCall) throws -> JSONObject {
    if let argumentsError = toolCall.argumentsError {
        throw ToolValidationError("Invalid arguments for tool \"\(toolCall.name)\": \(argumentsError)")
    }
    var errors: [(path: String, message: String)] = []
    let value = coerce(.object(toolCall.arguments), schema: tool.parameters, path: "", errors: &errors)
    if errors.isEmpty, let object = value.objectValue {
        return object
    }
    if errors.isEmpty {
        errors.append(("root", "must be object"))
    }
    let lines = errors.map { "  - \($0.path.isEmpty ? "root" : $0.path): \($0.message)" }.joined(separator: "\n")
    throw ToolValidationError(
        "Validation failed for tool \"\(toolCall.name)\":\n\(lines)\n\nReceived arguments:\n\(JSONValue.object(toolCall.arguments).jsonString(pretty: true))"
    )
}

private func joinPath(_ path: String, _ key: String) -> String {
    path.isEmpty ? key : "\(path).\(key)"
}

private func schemaTypes(_ schema: JSONObject) -> [String] {
    if let type = schema["type"]?.stringValue { return [type] }
    if let types = schema["type"]?.arrayValue { return types.compactMap(\.stringValue) }
    return []
}

private func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string), ("array", .array), ("object", .object):
        true
    case let ("integer", .number(number)):
        number.rounded() == number
    default:
        false
    }
}

/// The value converted to `type` where a model's sloppiness makes the intent clear, or nil.
private func convert(_ value: JSONValue, to type: String) -> JSONValue? {
    switch (type, value) {
    case let ("number", .string(text)), let ("integer", .string(text)):
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        if type == "integer", number.rounded() != number { return nil }
        return .number(number)
    case let ("boolean", .string(text)):
        switch text.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return nil
        }
    case let ("string", .number(number)):
        return .string(number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number))
    case let ("string", .bool(flag)):
        return .string(String(flag))
    case let ("array", value):
        if case .null = value { return nil }
        // A JSON array sent as a string.
        if case let .string(text) = value, let parsed = try? JSONValue.parse(text), case .array = parsed { return parsed }
        return .array([value])
    case let ("object", .string(text)):
        if let parsed = try? JSONValue.parse(text), case .object = parsed { return parsed }
        return nil
    default:
        return nil
    }
}

private func coerce(_ value: JSONValue, schema: JSONValue, path: String, errors: inout [(path: String, message: String)]) -> JSONValue {
    guard let schema = schema.objectValue else { return value }

    for key in ["anyOf", "oneOf"] {
        if let options = schema[key]?.arrayValue {
            for option in options {
                var optionErrors: [(path: String, message: String)] = []
                let result = coerce(value, schema: option, path: path, errors: &optionErrors)
                if optionErrors.isEmpty { return result }
            }
            errors.append((path, "must match a schema in \(key)"))
            return value
        }
    }

    var value = value
    let types = schemaTypes(schema)
    if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
        if let converted = types.lazy.compactMap({ convert(value, to: $0) }).first {
            value = converted
        } else {
            errors.append((path, "must be \(types.joined(separator: " or "))"))
            return value
        }
    }

    if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
        errors.append((path, "must be one of \(JSONValue.array(allowed).jsonString())"))
    }
    if let constant = schema["const"], constant != value {
        errors.append((path, "must be \(constant.jsonString())"))
    }

    switch value {
    case let .number(number):
        if let minimum = schema["minimum"]?.doubleValue, number < minimum { errors.append((path, "must be >= \(JSONValue.number(minimum).jsonString())")) }
        if let maximum = schema["maximum"]?.doubleValue, number > maximum { errors.append((path, "must be <= \(JSONValue.number(maximum).jsonString())")) }
    case let .string(text):
        if let minLength = schema["minLength"]?.intValue, text.count < minLength { errors.append((path, "must have at least \(minLength) characters")) }
        if let maxLength = schema["maxLength"]?.intValue, text.count > maxLength { errors.append((path, "must have at most \(maxLength) characters")) }
    case let .array(items):
        if let minItems = schema["minItems"]?.intValue, items.count < minItems { errors.append((path, "must have at least \(minItems) items")) }
        if let maxItems = schema["maxItems"]?.intValue, items.count > maxItems { errors.append((path, "must have at most \(maxItems) items")) }
        if let itemSchema = schema["items"] {
            value = .array(items.enumerated().map { index, item in
                coerce(item, schema: itemSchema, path: joinPath(path, String(index)), errors: &errors)
            })
        }
    case var .object(object):
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        for (key, propertyValue) in object {
            if case .null = propertyValue, !required.contains(key), let propertySchema = properties[key],
               !schemaTypes(propertySchema.objectValue ?? [:]).contains("null")
            {
                // `null` for an omitted optional property.
                object[key] = nil
                continue
            }
            if let propertySchema = properties[key] {
                object[key] = coerce(propertyValue, schema: propertySchema, path: joinPath(path, key), errors: &errors)
            } else if schema["additionalProperties"] == .bool(false) {
                errors.append((joinPath(path, key), "is not an allowed property"))
            }
        }
        for key in required.sorted() where object[key] == nil {
            errors.append((path, "must have required property '\(key)'"))
        }
        value = .object(object)
    default:
        break
    }
    return value
}
