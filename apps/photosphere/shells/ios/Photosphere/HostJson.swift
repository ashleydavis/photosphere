//
// Reading the JSON text a host request carries and writing the JSON text it answers with.
//

import Foundation
import ZiggyShellIOS

// Helpers for the JSON of host requests.
enum HostJson {
    // Reads the request's argument, which must be a JSON object.
    static func object(from json: String, method: String) throws -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ZiggyHostRequestError("The request \(method) was not understood: its argument is not a JSON object.")
        }
        return parsed
    }

    // Reads a field of the request that must be text.
    static func string(_ request: [String: Any], _ name: String, method: String) throws -> String {
        guard let value = request[name] as? String else {
            throw ZiggyHostRequestError("The request \(method) was not understood: \"\(name)\" is missing or is not text.")
        }
        return value
    }

    // Reads a field of the request that must be a list of text.
    static func strings(_ request: [String: Any], _ name: String, method: String) throws -> [String] {
        guard let value = request[name] as? [String] else {
            throw ZiggyHostRequestError("The request \(method) was not understood: \"\(name)\" is missing or is not a list of text.")
        }
        return value
    }

    // Writes a JSON array or object.
    static func text(from value: Any, method: String) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ZiggyHostRequestError("The answer to \(method) could not be written as JSON.")
        }
        do {
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        catch {
            throw ZiggyHostRequestError("The answer to \(method) could not be written as JSON: \(error)")
        }
    }

    // Writes text as a JSON string.
    static func quote(_ text: String, method: String) throws -> String {
        do {
            return String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        }
        catch {
            throw ZiggyHostRequestError("The answer to \(method) could not be written as JSON: \(error)")
        }
    }
}
