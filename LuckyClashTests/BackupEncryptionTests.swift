import Foundation
import Testing
@testable import LuckyClash

struct BackupEncryptionTests {
    @Test func encryptionAuthenticatesPasswordAndContents() throws {
        let original = Data("configuration with credentials".utf8)
        let first = try BackupEncryption.seal(original, password: "correct horse")
        let second = try BackupEncryption.seal(original, password: "correct horse")
        #expect(first != second)
        #expect(try BackupEncryption.open(first, password: "correct horse") == original)
        #expect(throws: (any Error).self) {
            try BackupEncryption.open(first, password: "wrong")
        }
        var tampered = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let ciphertext = try #require(tampered["ciphertext"] as? String)
        var encrypted = try #require(Data(base64Encoded: ciphertext))
        encrypted[encrypted.startIndex] ^= 1
        tampered["ciphertext"] = encrypted.base64EncodedString()
        let modified = try JSONSerialization.data(withJSONObject: tampered)
        #expect(throws: (any Error).self) {
            try BackupEncryption.open(modified, password: "correct horse")
        }
        tampered["iterations"] = 1
        let altered = try JSONSerialization.data(withJSONObject: tampered)
        #expect(throws: (any Error).self) {
            try BackupEncryption.open(altered, password: "correct horse")
        }
    }
}
