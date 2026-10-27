// Signs Lumen updates with Ed25519, so Lumen only installs updates made with your key.
//   swift tools/sign-update.swift keygen        creates the key pair once and prints the public key
//   swift tools/sign-update.swift public        prints the public key again
//   swift tools/sign-update.swift sign <file>   writes <file>.sig, to upload next to the file
// The private key stays in ~/.config/lumen/update-signing.key. Never commit it or upload it.
import Foundation
import CryptoKit

let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lumen/update-signing.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key at \(keyFile.path). Run: swift tools/sign-update.swift keygen")
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    guard !FileManager.default.fileExists(atPath: keyFile.path) else { fail("A key already exists at \(keyFile.path). Not overwriting it.") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (key.rawRepresentation.base64EncodedString() + "\n").write(to: keyFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2, let path = args.dropFirst().first else { fail("Usage: sign <file>") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { fail("Can't read \(path)") }
    let signature = try loadKey().signature(for: data)
    try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print(path + ".sig")
default:
    fail("Usage: keygen | public | sign <file>")
}
