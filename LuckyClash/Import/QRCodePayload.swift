import CoreImage

nonisolated enum QRCodePayload {
    /// Extracts the subscription URL from a FlClash-style QR payload. The code
    /// may hold a plain HTTPS link or a `clash://install-config?url=` /
    /// `luckyclash://install-config?url=` deep link.
    static func subscriptionURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           ["clash", "luckyclash"].contains(scheme) {
            let target = components.queryItems?
                .first(where: { $0.name.lowercased() == "url" })?.value
            return target.flatMap { RemoteImport.url(from: $0) }
        }
        return RemoteImport.url(from: trimmed)
    }

    /// Decodes the first QR code in an image picked from the photo library.
    static func decode(imageData: Data) -> String? {
        guard let image = CIImage(data: imageData),
              let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ) else {
            return nil
        }
        return (detector.features(in: image) as? [CIQRCodeFeature])?
            .compactMap(\.messageString)
            .first
    }
}
