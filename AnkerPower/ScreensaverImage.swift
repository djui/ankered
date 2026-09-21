import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreensaverImage {
    static let pixelSize = 240
    static let jpegQuality: CGFloat = 0.85
    static let vignetteWidth: CGFloat = 16
    static let chunkPayloadSize = AnkerSession.screensaverChunkPayloadSize
    static let acknowledgeEvery = AnkerSession.screensaverAcknowledgeEvery
    static let slotCount = 4

    struct Crop: Equatable, Sendable {
        var zoom: CGFloat = 1
        var pan: CGSize = .zero

        static let identity = Crop()
    }

    struct Plan: Equatable, Sendable {
        let jpeg: Data
        let pictureID: UInt32
        let hash: UInt32
        let chunkCount: Int
        let padding: Int

        var reportedID: UInt16 { UInt16(truncatingIfNeeded: pictureID) }

        init?(jpeg: Data) {
            guard !jpeg.isEmpty else { return nil }
            let count = ScreensaverImage.chunkCount(forByteCount: jpeg.count)
            guard count > 0, count <= Int(UInt16.max) else { return nil }
            self.jpeg = jpeg
            self.hash = ScreensaverImage.crc32(jpeg)
            self.pictureID = hash
            self.chunkCount = count
            self.padding = count * chunkPayloadSize - jpeg.count
        }
    }

    static func chunkCount(forByteCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (count + chunkPayloadSize - 1) / chunkPayloadSize
    }

    static func chunk(_ data: Data, at index: Int) -> Data? {
        let count = chunkCount(forByteCount: data.count)
        guard (0..<count).contains(index) else { return nil }
        let start = index * chunkPayloadSize
        let end = min(start + chunkPayloadSize, data.count)
        var payload = data.subdata(in: start..<end)
        if payload.count < chunkPayloadSize {
            payload.append(Data(count: chunkPayloadSize - payload.count))
        }
        return payload
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc >> 1) ^ (0xEDB8_8320 & ~((crc & 1) &- 1))
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func cropRect(imageSize: CGSize, crop: Crop) -> CGRect {
        let width = max(imageSize.width, 1)
        let height = max(imageSize.height, 1)
        let fill = min(width, height)
        let side = max(1, fill / max(crop.zoom, 1))
        let slackX = max(0, (width - side) / 2)
        let slackY = max(0, (height - side) / 2)
        let x = slackX + crop.pan.width * slackX
        let y = slackY + crop.pan.height * slackY
        return CGRect(
            x: min(max(0, x), width - side),
            y: min(max(0, y), height - side),
            width: side,
            height: side
        )
    }

    static func encode(
        image: CGImage,
        crop: Crop = .identity,
        vignette: Bool
    ) throws -> Plan {
        guard let rendered = render(image: image, crop: crop, vignette: vignette),
              let jpeg = jpegData(from: rendered),
              let plan = Plan(jpeg: jpeg) else {
            throw ScreensaverTransferError.emptyImage
        }
        return plan
    }

    static func render(image: CGImage, crop: Crop, vignette: Bool) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let source = cropRect(imageSize: imageSize, crop: crop)
        let size = pixelSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let crop = source.integral
        if let piece = image.cropping(to: crop) {
            context.draw(piece, in: CGRect(x: 0, y: 0, width: size, height: size))
        } else {
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        if vignette {
            applyVignette(in: context, size: size)
        }
        return context.makeImage()
    }

    static func applyVignette(in context: CGContext, size: Int, width: CGFloat = vignetteWidth) {
        guard let data = context.data else { return }
        let bytesPerRow = context.bytesPerRow
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * size)
        let fade = max(width, 1)
        for y in 0..<size {
            for x in 0..<size {
                let edge = min(CGFloat(x), CGFloat(y), CGFloat(size - 1 - x), CGFloat(size - 1 - y))
                guard edge < fade else { continue }
                let t = 1 - edge / fade
                let amount = t * t * (3 - 2 * t)
                let offset = y * bytesPerRow + x * 4
                let keep = 1 - amount
                buffer[offset] = UInt8((CGFloat(buffer[offset]) * keep).rounded())
                buffer[offset + 1] = UInt8((CGFloat(buffer[offset + 1]) * keep).rounded())
                buffer[offset + 2] = UInt8((CGFloat(buffer[offset + 2]) * keep).rounded())
            }
        }
    }

    static func jpegData(from image: CGImage, quality: CGFloat = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func solidImage(color: CGColor, size: Int = pixelSize) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}

extension NSImage {
    var screensaverCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        if let image = cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return image
        }
        guard let tiff = tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
