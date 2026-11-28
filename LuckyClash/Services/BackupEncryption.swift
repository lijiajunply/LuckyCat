import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Versioned authenticated envelope for backups containing subscription credentials.
nonisolated enum BackupEncryption {
    private static let version = 1
    private static let iterations: UInt32 = 210_000
    private static let saltLength = 16
    static let maximumSize = 64 * 1024 * 1024

    private struct Envelope: Codable {
        let version: Int
        let iterations: UInt32
        let salt: Data
        let ciphertext: Data
    }

    enum Failure: LocalizedError {
        case passwordRequired
        case invalidBackup
        case cryptography

        var errorDescription: String? {
            switch self {
            case .passwordRequired: "请输入备份密码。"
            case .invalidBackup: "备份无效或密码不正确。"
            case .cryptography: "无法加密备份。"
            }
        }
    }

    static func seal(_ data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw Failure.passwordRequired }
        guard data.count <= maximumSize else { throw Failure.invalidBackup }
        var salt = Data(count: saltLength)
        guard salt.withUnsafeMutableBytes({ bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!) == errSecSuccess
        }) else { throw Failure.cryptography }
        let key = try deriveKey(password: password, salt: salt, rounds: iterations)
        let encrypted = try AES.GCM.seal(data, using: key)
        guard let combined = encrypted.combined else { throw Failure.cryptography }
        return try JSONEncoder().encode(Envelope(
            version: version, iterations: iterations, salt: salt, ciphertext: combined
        ))
    }

    static func open(_ encoded: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw Failure.passwordRequired }
        // Base64-encoded JSON expands the encrypted payload by roughly one third.
        guard encoded.count <= maximumSize * 2,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: encoded),
              envelope.version == version, envelope.iterations == iterations,
              envelope.salt.count == saltLength, envelope.ciphertext.count <= maximumSize + 28 else {
            throw Failure.invalidBackup
        }
        do {
            let key = try deriveKey(password: password, salt: envelope.salt, rounds: envelope.iterations)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key)
        } catch {
            throw Failure.invalidBackup
        }
    }

    private static func deriveKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let pass = Array(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                pass.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.cryptography }
        return SymmetricKey(data: derived)
    }
}
