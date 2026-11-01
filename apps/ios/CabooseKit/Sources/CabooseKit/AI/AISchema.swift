#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// JSON Schema, as programs give it for tool parameters and structured answers, as the
/// generation schema Apple's models are guided by. The supported subset: objects with
/// `properties` and `required`, `string` (with `enum` and `const`), `integer` and `number`
/// (with `minimum` and `maximum`), `boolean`, `array` (with `items`, `minItems`, `maxItems`),
/// `anyOf` and `oneOf`, a `type` list with `"null"` (an optional property), and `$ref` to
/// `$defs` or `definitions`. Keywords outside it (`pattern`, `format`, `additionalProperties`)
/// are not enforced. A schema with nothing the model can be guided by fails with the reason.
@available(iOS 26.0, macOS 26.0, *)
public enum AISchema {
    public struct Unsupported: Error, Equatable { public let reason: String }

    public static func generationSchema(_ schema: AIJSON, name: String) throws -> GenerationSchema {
        var converter = Converter(root: schema)
        let root = try converter.convert(schema, name: Converter.clean(name), depth: 0)
        do {
            return try GenerationSchema(root: root, dependencies: converter.dependencies)
        } catch {
            throw Unsupported(reason: "The schema cannot guide the model: \(error.localizedDescription)")
        }
    }

    struct Converter {
        let root: AIJSON
        var dependencies: [DynamicGenerationSchema] = []
        var defined: Set<String> = []
        var names: Set<String> = []

        init(root: AIJSON) { self.root = root }

        static func clean(_ name: String) -> String {
            let cleaned = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_" })
            return cleaned.isEmpty ? "Schema" : cleaned
        }

        /// Object and choice schemas need names unique in the whole schema.
        mutating func unique(_ name: String) -> String {
            var candidate = Self.clean(name)
            var index = 2
            while names.contains(candidate) { candidate = "\(Self.clean(name))\(index)"; index += 1 }
            names.insert(candidate)
            return candidate
        }

        mutating func convert(_ schema: AIJSON, name: String, depth: Int) throws -> DynamicGenerationSchema {
            guard depth < 24 else { throw Unsupported(reason: "The schema is nested too deeply.") }
            let description = schema["description"]?.string
            if let reference = schema["$ref"]?.string { return try referenced(reference, depth: depth) }
            if let choices = (schema["anyOf"] ?? schema["oneOf"])?.array {
                let options = choices.filter { $0["type"]?.string != "null" }
                if options.count == 1 { return try convert(options[0], name: name, depth: depth + 1) }
                guard !options.isEmpty else { throw Unsupported(reason: "\(name) has no choice the model can make.") }
                let base = unique(name)
                return DynamicGenerationSchema(name: base, description: description,
                                               anyOf: try options.enumerated().map { try convert($1, name: "\(base)_\($0 + 1)", depth: depth + 1) })
            }
            if let constant = schema["const"] {
                guard let text = constant.string else { throw Unsupported(reason: "\(name): only string constants are supported.") }
                return DynamicGenerationSchema(name: unique(name), description: description, anyOf: [text])
            }
            if let values = schema["enum"]?.array {
                let texts = values.compactMap(\.string)
                guard texts.count == values.count, !texts.isEmpty else { throw Unsupported(reason: "\(name): only string enums are supported.") }
                return DynamicGenerationSchema(name: unique(name), description: description, anyOf: texts)
            }
            switch kind(of: schema) {
            case "string": return DynamicGenerationSchema(type: String.self)
            case "boolean": return DynamicGenerationSchema(type: Bool.self)
            case "integer":
                var guides: [GenerationGuide<Int>] = []
                if let low = schema["minimum"]?.integer { guides.append(.minimum(low)) }
                if let high = schema["maximum"]?.integer { guides.append(.maximum(high)) }
                return DynamicGenerationSchema(type: Int.self, guides: guides)
            case "number":
                var guides: [GenerationGuide<Double>] = []
                if let low = schema["minimum"]?.number { guides.append(.minimum(low)) }
                if let high = schema["maximum"]?.number { guides.append(.maximum(high)) }
                return DynamicGenerationSchema(type: Double.self, guides: guides)
            case "array":
                let items = try convert(schema["items"] ?? .object([("type", .string("string"))]), name: "\(name)_item", depth: depth + 1)
                return DynamicGenerationSchema(arrayOf: items, minimumElements: schema["minItems"]?.integer, maximumElements: schema["maxItems"]?.integer)
            case "object":
                let required = Set(schema["required"]?.array?.compactMap(\.string) ?? [])
                let base = unique(name)
                let properties = try (schema["properties"]?.pairs ?? []).map { property in
                    let optional = !required.contains(property.key) || Self.nullable(property.value)
                    return DynamicGenerationSchema.Property(name: property.key, description: property.value["description"]?.string,
                                                            schema: try convert(property.value, name: "\(base)_\(property.key)", depth: depth + 1), isOptional: optional)
                }
                return DynamicGenerationSchema(name: base, description: description, properties: properties)
            case let other:
                throw Unsupported(reason: "\(name) has type \(other), which the model cannot be guided by.")
            }
        }

        /// The schema's type: its `type`, the one besides `"null"` in a list, or what its keywords imply.
        func kind(of schema: AIJSON) -> String {
            if let type = schema["type"]?.string { return type }
            if let types = schema["type"]?.array?.compactMap(\.string).filter({ $0 != "null" }), types.count == 1 { return types[0] }
            if schema["properties"] != nil { return "object" }
            if schema["items"] != nil { return "array" }
            if schema["type"] == nil, schema.pairs?.isEmpty ?? false { return "string" }
            return schema["type"]?.text ?? "unknown"
        }

        static func nullable(_ schema: AIJSON) -> Bool {
            schema["type"]?.array?.contains(.string("null")) == true
                || (schema["anyOf"] ?? schema["oneOf"])?.array?.contains { $0["type"]?.string == "null" } == true
        }

        mutating func referenced(_ reference: String, depth: Int) throws -> DynamicGenerationSchema {
            let parts = reference.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0] == "#", parts[1] == "$defs" || parts[1] == "definitions",
                  let target = root[parts[1]]?[parts[2]] else { throw Unsupported(reason: "Only $ref to #/$defs/… or #/definitions/… is supported.") }
            let name = Self.clean(parts[2])
            let named = target["properties"] != nil || target["anyOf"] != nil || target["oneOf"] != nil || target["enum"] != nil || target["const"] != nil || kind(of: target) == "object"
            // A definition without a name of its own (a string, an array) is written in place.
            guard named else { return try convert(target, name: name, depth: depth + 1) }
            if !defined.contains(name) {
                // Marked first, so a recursive reference resolves to it instead of recursing.
                defined.insert(name)
                dependencies.append(try convert(target, name: name, depth: depth + 1))
            }
            return DynamicGenerationSchema(referenceTo: name)
        }
    }
}
#endif
