import Foundation
import TypedStream
import Logging

private let logger = Logger(label: "imessage-mcp.decoder")

/// Decodes the `attributedBody` blob from the `message` table in `chat.db`.
///
/// Many iMessages have `text = NULL` with the actual content stored only in the
/// `attributedBody` column as a serialized `NSAttributedString`. The encoding format
/// varies by macOS version and message type:
///
/// - **NSKeyedArchiver** — standard Foundation serialization. Works for simple text messages
///   on modern macOS. Fastest method.
/// - **TypedStream** — Apple's legacy binary serialization (predates NSCoding). Used for
///   older messages and certain edge cases. Handled by the Madrid library's `TypedStreamDecoder`.
/// - **Heuristic fallback** — Scans raw bytes for an `"NSString"` marker and extracts
///   printable ASCII runs. ~85% accurate; occasionally includes trailing metadata cruft
///   that `stripMetadataSuffix()` cleans up. Last resort.
///
/// Adapted from the `iMessageBridge` version; uses `swift-log` instead of `os.Logger`.
public enum MessageDecoder {
    /// Attempts to decode the `attributedBody` blob, trying four methods in order
    /// of reliability. Returns the decoded text, or `nil` if all methods fail.
    public static func decode(attributedBody: Data) -> String? {
        // Method 1: Try NSKeyedUnarchiver with NSAttributedString (fastest, sometimes works)
        if let decoded = tryNSKeyedUnarchiver(attributedBody) {
            logger.debug("NSKeyedUnarchiver decode success: \(decoded.prefix(50))...")
            return decoded
        }
        
        // Method 2: Try Madrid's TypedStream decoder (accurate, handles most cases)
        if let decoded = tryTypedStreamDecoder(attributedBody) {
            logger.debug("TypedStream decode success: \(decoded.prefix(50))...")
            return decoded
        }
        
        // Method 3: Try unarchiveTopLevelObjectWithData (alternative API)
        if let decoded = tryUnarchiveTopLevel(attributedBody) {
            logger.debug("UnarchiveTopLevel decode success: \(decoded.prefix(50))...")
            return decoded
        }
        
        // Method 4: Heuristic fallback (last resort, ~85% accurate)
        if let decoded = tryExtractUTF8String(attributedBody) {
            logger.debug("Heuristic fallback decode: \(decoded.prefix(50))...")
            return decoded
        }
        
        logger.warning("All decode methods failed for \(attributedBody.count) byte blob")
        return nil
    }
    
    /// Method 1: Standard NSKeyedUnarchiver approach
    private static func tryNSKeyedUnarchiver(_ data: Data) -> String? {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            if let attributedString = try? NSAttributedString(coder: unarchiver) {
                unarchiver.finishDecoding()
                let text = attributedString.string.stripMetadataSuffix()
                return text.isEmpty ? nil : text
            }
            unarchiver.finishDecoding()
        } catch {
            // Unarchiver failed, try next method
        }
        return nil
    }
    
    /// Method 2: Madrid's TypedStream decoder
    private static func tryTypedStreamDecoder(_ data: Data) -> String? {
        do {
            let results = try TypedStreamDecoder.decode(data)
            
            // Look for NSString objects in the results
            for result in results {
                if let stringValue = result.stringValue {
                    let cleaned = stringValue
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .stripMetadataSuffix()
                    
                    if !cleaned.isEmpty {
                        return cleaned
                    }
                }
            }
            
            if !results.isEmpty {
                logger.debug("TypedStream decoded \(results.count) objects but no NSString found")
            }
            
        } catch {
            logger.debug("TypedStream decode failed: \(error)")
        }
        return nil
    }
    
    /// Method 3: Try unarchiving with the class-based API
    private static func tryUnarchiveTopLevel(_ data: Data) -> String? {
        do {
            if let object = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {
                if let attrString = object as? NSAttributedString {
                    let text = attrString.string
                    return text.isEmpty ? nil : text
                }
                if let string = object as? String {
                    return string.isEmpty ? nil : string
                }
            }
        } catch {
            // This method failed, try next
        }
        return nil
    }
    
    /// Method 4: Heuristic - try to find UTF-8 strings in the blob
    private static func tryExtractUTF8String(_ data: Data) -> String? {
        // Look for "NSString" marker (common in NSAttributedString encoding)
        if let range = data.range(of: "NSString".data(using: .utf8)!) {
            let afterMarker = data[range.upperBound...]
            
            guard afterMarker.count > 10 else { return nil }
            let searchData = afterMarker.dropFirst(4)
            
            if let text = extractPrintableText(from: searchData) {
                return text
            }
        }
        
        if let allText = String(data: data, encoding: .utf8) {
            let cleaned = allText.filter { $0.isASCII && ($0.isPrintable || $0.isNewline || $0.isWhitespace) }
            return cleaned.isEmpty ? nil : cleaned
        }
        
        return nil
    }
    
    /// Extract printable text from binary data
    private static func extractPrintableText(from data: Data) -> String? {
        var result = ""
        var currentRun = ""
        
        for byte in data {
            let char = Character(UnicodeScalar(byte))
            if char.isASCII && (char.isPrintable || char.isNewline || char.isWhitespace) {
                currentRun.append(char)
            } else {
                if currentRun.count > 3 {
                    result += currentRun
                }
                currentRun = ""
            }
        }
        
        if currentRun.count > 3 {
            result += currentRun
        }
        
        let cleaned = result
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .stripMetadataSuffix()
        
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Helper Extensions

private extension Character {
    var isPrintable: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 32 && ascii <= 126
    }
}

private extension String {
    /// Remove common NSAttributedString metadata suffixes
    func stripMetadataSuffix() -> String {
        let metadataSuffixes = [
            "NSDictionary__kIMMessagePartAttributeNameNSNumberNSValue",
            "__kIMMessagePartAttributeNameNSNumberNSValue",
            "__kIMMessagePartAttributeName",
            "NSDictionary",
            "NSNumber",
            "NSValue"
        ]
        
        var result = self
        for suffix in metadataSuffixes {
            if let range = result.range(of: suffix, options: [.backwards]) {
                result = String(result[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}
