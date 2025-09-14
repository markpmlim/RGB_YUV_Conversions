import AppKit
import Accelerate.vImage
import PlaygroundSupport

/// Edit these 2 names
let inputFilename = "Hibiscus.png"      // PinkFlower.jpg
let outputFilename = "Hibiscus444p.yuv"

// Convert from CoreGraphics to vImageYpCbCrType
//              OSType                          vImageYpCbCrType
//
// kCVPixelFormatType_444YpCbCr8 (v308)         kvImage444CrYpCb8
// cf: CVPixelBuffer.h, vImage_Types.h

func configureInfo() -> vImage_ARGBToYpCbCr
{
    var info = vImage_ARGBToYpCbCr()    // filled with zeroes
    
    // video range 8-bit, unclamped
    var pixelRange = vImage_YpCbCrPixelRange(
        Yp_bias: 16,
        CbCr_bias: 128,
        YpRangeMax: 235,
        CbCrRangeMax: 240,
        YpMax: 255,
        YpMin: 0,
        CbCrMax: 255,
        CbCrMin: 1)
    
    // The contents of `info` object is initialised by the call below. It
    // will be used by the function vImageConvert_ARGB8888To444CrYpCb8
    let error = vImageConvert_ARGBToYpCbCr_GenerateConversion(
        kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4,
        &pixelRange,
        &info,
        kvImageARGB8888,
        kvImage444CrYpCb8,    // v308
        vImage_Flags(kvImageDoNotTile))
    
    return info
}

//// Main code
guard let nsImage = NSImage(named: NSImage.Name(inputFilename))
else {
    fatalError("File not found")
}
guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fatalError("Image may be corrupted")
}
// prints 5 (noneSkipLast which is RGBX)
//print(cgImage.bitmapInfo.rawValue)  // RGBX
var rgbaSourceBuffer = try! vImage_Buffer(cgImage: cgImage)

var bufferPtr = rgbaSourceBuffer.data.assumingMemoryBound(to: UInt8.self)
/*
 R    G    B    A  |   R   G    B    A
0xD4 0xA0 0x69 0xFF 0xCA 0x96 0x59 0xFF
 */
for i in 0 ..< 2 * 4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

let width = Int(rgbaSourceBuffer.width)
let height = Int(rgbaSourceBuffer.height)
// A0 R0 G0 B0 --> Cr0 Yp0 Cb0
// 4 bytes of RGBA are converted to 3 bytes of yCbCr
let memoryPtr = malloc(width*3*height)
// The CrYpCb buffer below must have the the same dimensions as the RGBA source buffer.
// Their `rowBytes` values are different.
var crycbSourceBuffer = vImage_Buffer(
    data: memoryPtr,
    height: vImagePixelCount(height),
    width: vImagePixelCount(width),
    rowBytes: width*3)

print(rgbaSourceBuffer)
print(crycbSourceBuffer)

var infoARGBToYpCbCr = configureInfo()
var error = vImageConvert_ARGB8888To444CrYpCb8(
    &rgbaSourceBuffer,
    &crycbSourceBuffer,
    &infoARGBToYpCbCr,
    [3,0,1,2],      // RGBX --> XRGB
    vImage_Flags(kvImagePrintDiagnosticsToConsole))

// `crycbSourceBuffer` is now populated with yCbCr pixels
/*
 Cr0   Yp0  Cb0  | Cr1   Yp1  Cb1  | Cr2  Yp2  Cb2  | Cr3   Yp3  Cb3  | Cr4   Yp4  Cb4  | Cr5  Yp5  Cb5
 0x9B 0xA1  0x60 | 0x9B  0x98 0x5E | 0x9C 0x94 0x5A | 0x9B  0x93 0x57 | 0x9B  0x94 0x58 | 0x9E 0x94 0x5B
 */
bufferPtr = crycbSourceBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 3 * 6 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

// Create 3 vImage_Buffer objects whose data regions are the 2D destination planes.
// All 3 vImage_Buffer objects have the same width, height and `rowBytes` values
let yBuffer = try! vImage_Buffer(
    width: width,
    height: height,
    bitsPerPixel: 8)

let cbBuffer = try! vImage_Buffer(
    width: width,
    height: height,
    bitsPerPixel: 8)

let crBuffer = try! vImage_Buffer(
    width: width,
    height: height,
    bitsPerPixel: 8)

print(yBuffer)
print(cbBuffer)
print(crBuffer)

_ = withUnsafePointer(to: crycbSourceBuffer) {
    (crycb: UnsafePointer<vImage_Buffer>) in
    withUnsafePointer(to: crBuffer) {
        (cr: UnsafePointer<vImage_Buffer>) in
        withUnsafePointer(to: yBuffer) {
            (y: UnsafePointer<vImage_Buffer>) in
            withUnsafePointer(to: cbBuffer) {
                (cb: UnsafePointer<vImage_Buffer>) in

                var srcChannels = [
                    UnsafeRawPointer(crycb.pointee.data),
                    UnsafeRawPointer(crycb.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride)),
                    UnsafeRawPointer(crycb.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride*2))
                ]
                var destPlanarBuffers = [Optional(cr), Optional(y), Optional(cb)]
                let channelCount = 3

                _ = vImageConvert_ChunkyToPlanar8(
                    &srcChannels,
                    &destPlanarBuffers,
                    UInt32(channelCount),
                    MemoryLayout<Pixel_8>.stride * channelCount,
                    vImagePixelCount(width),
                    vImagePixelCount(height),
                    crycb.pointee.rowBytes,
                    vImage_Flags(kvImageNoFlags))
            }
        }
    }
}

// Print out some bytes
bufferPtr = crBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 3 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

bufferPtr = yBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 3 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()
bufferPtr = cbBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 3 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

var grayScaleImageFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 8,
    colorSpace: Unmanaged.passRetained(CGColorSpace(name: CGColorSpace.linearGray)!),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
    version: 0,
    decode: nil,
    renderingIntent: .defaultIntent)

// Provide a visual check of the data in the 3 planes.
let luminanceImage = try! yBuffer.createCGImage(format: grayScaleImageFormat)
let cbImage = try! cbBuffer.createCGImage(format: grayScaleImageFormat)
let crImage = try! crBuffer.createCGImage(format: grayScaleImageFormat)


/*
 Merge the 2D data regions of the 3 vImage_Buffers into a single memory block.
 Caller must free the memory allocated.
 */
let buffers = [yBuffer, cbBuffer, crBuffer]
let lumaFrameSize = Int(yBuffer.height) * Int(yBuffer.width)
let chromaFrameSize = Int(cbBuffer.height) * Int(cbBuffer.width)

func mergeBuffers() -> UnsafeMutableRawPointer?
{
    let yPlane = malloc(lumaFrameSize)      // UnsafeMutableRawPointer
    let uPlane = malloc(chromaFrameSize)
    let vPlane = malloc(chromaFrameSize)
    let planes = [yPlane, uPlane, vPlane]
    
    // Safer to copy row-by-row because the `rowBytes` property of each vImage_Buffer might be
    // greater than its `width` property.
    for planeIndex in 0 ..< planes.count {
        var destPointer = planes[planeIndex]            // UnsafeMutableRawPointer
        let width =  Int(buffers[planeIndex].width)
        let height = Int(buffers[planeIndex].height)
        let rowBytes = buffers[planeIndex].rowBytes
        var sourcePointer = buffers[planeIndex].data    // UnsafeMutableRawPointer
        for _ in 0 ..< height {
            memcpy(destPointer, sourcePointer, width)
            sourcePointer = sourcePointer! + rowBytes
            destPointer = destPointer! + width
        }
    }

    // Merge the planes into a single memory block
    let bytes2Copy = [lumaFrameSize, chromaFrameSize, chromaFrameSize]
    let totalSize = lumaFrameSize + chromaFrameSize*2
    var memPtr = malloc(totalSize)
    let memoryBlock = memPtr
    for i in 0..<planes.count {
        let baseAddress = planes[i]
        memcpy(memPtr, baseAddress, bytes2Copy[i])
        memPtr = memPtr?.advanced(by: bytes2Copy[i])
    }
    free(yPlane)
    free(uPlane)
    free(vPlane)

    return memoryBlock
}

let dataBlock = mergeBuffers()
let directoryURL = playgroundSharedDataDirectory
let totalSize = lumaFrameSize + chromaFrameSize*2

let writeURL = directoryURL.appendingPathComponent(outputFilename)

// a) Write out the raw yuv data to a file
// b) To test the merged raw yuv file.
let fileData =  Data(bytes: dataBlock!, count: totalSize)
try! fileData.write(to: writeURL, options: [])

dataBlock?.deallocate()
rgbaSourceBuffer.free()
crycbSourceBuffer.free()
yBuffer.free()
cbBuffer.free()
crBuffer.free()

//: [Next](@next)
