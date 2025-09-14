
import AppKit
import Accelerate.vImage
import PlaygroundSupport

/// Edit these 2 names
let inputFilename = "PinkFlower.jpg"    // Hibiscus.png
let outputFilename = "PinkFlower422p.yuv"

// Convert from CoreGraphics to vImageYpCbCrType and back
//              OSType                                  vImageYpCbCrType
// kCVPixelFormatType_422YpCbCr8 (2vuy/2vuf)        kvImage422CbYpCrYp8
// kCVPixelFormatType_422YpCbCr8_yuvs (yuvs)        kvImage422YpCbYpCr8
// kCVPixelFormatType_422YpCbCr8FullRange (yuvf)    kvImage422YpCbYpCr8
// cf: CVPixelBuffer.h, vImage_Types.h

guard let metalDevice = MTLCreateSystemDefaultDevice()
else {
    fatalError("Metal is not supported")
}
let colorSpace = CGColorSpaceCreateDeviceRGB()
let options = [
    CIContextOption.outputColorSpace : colorSpace,
    CIContextOption.workingFormat : CIFormat.RG8,
] as [CIContextOption : Any]

let ciContext = CIContext(mtlDevice: metalDevice,
                          options: options)

func createCIImage(from buffer: vImage_Buffer,
                   pixelFormat: MTLPixelFormat)  -> CIImage?
{
    var mtlTexture: MTLTexture? = nil
    
    let width = buffer.width
    let height = buffer.height
    let bytesPerRow = buffer.rowBytes
    let baseAddress = buffer.data

    let mtlDescr = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: Int(width), height: Int(height),
        mipmapped: false)

    mtlDescr.usage = [.shaderRead, .shaderWrite]
    mtlDescr.storageMode = .managed
    mtlTexture = metalDevice.makeTexture(descriptor: mtlDescr)
    let region = MTLRegionMake2D(0, 0,
                                 Int(width), Int(height))
    mtlTexture?.replace(region: region,
                        mipmapLevel: 0,
                        withBytes: baseAddress!,
                        bytesPerRow: bytesPerRow)   // the stride, in bytes, between rows of source data
    let ciImage = CIImage(mtlTexture: mtlTexture!, options: nil)
    return ciImage
}

func configureInfo() -> vImage_ARGBToYpCbCr {

    var info = vImage_ARGBToYpCbCr()    // filled with zeroes

    // full range 8-bit, clamped to full range
    var pixelRange = vImage_YpCbCrPixelRange(
        Yp_bias: 0,
        CbCr_bias: 128,
        YpRangeMax: 255,
        CbCrRangeMax: 255,
        YpMax: 255,
        YpMin: 0,
        CbCrMax: 255,
        CbCrMin: 0)

    // The contents of `info` object is initialised by the call below. It
    // will be used by the function vImageConvert_ARGB8888To422YpCbYpCr8
    let error = vImageConvert_ARGBToYpCbCr_GenerateConversion(
        kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4,
        &pixelRange,
        &info,
        kvImageARGB8888,
        kvImage422YpCbYpCr8,    // yuvf
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
print(rgbaSourceBuffer)
/*
 R    G    B    A   |  R    G    B    A
 0xD4 0xA0 0x69 0xFF | 0xCA 0x96 0x59 0xFF  // Hibiscus.png
 0x7A 0x5A 0x2B 0xFF | 0x84 0x6A 0x1F 0xFF  // sunflower.jpg
 */
var bufferPtr = rgbaSourceBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

/// Convert the RGBX to 422CbYpCrYp8
let width = Int(rgbaSourceBuffer.width)
let height = Int(rgbaSourceBuffer.height)
let memoryPtr = malloc(width*2*height)
// The yCbCr buffer below must have the the same dimensions as the RGBA source buffer
// Its `rowBytes` value should be half that of the latter vImage_Buffer object
var yCbCrSourceBuffer = vImage_Buffer(
    data: memoryPtr,
    height: vImagePixelCount(height),
    width: vImagePixelCount(width),
    rowBytes: width*2)

// A0 R0 G0 B0  A1 R1 G1 B1 -> Yp0 Cb0 Yp1 Cr0
// 8 bytes of RGBA is converted to 4 bytes of yCbCr
// Use the function vImageConvert_ARGB8888To422CbYpCrYp8 for 2vuy/2vuf
var infoARGBToYpCbCr = configureInfo()
var error = vImageConvert_ARGB8888To422YpCbYpCr8(
    &rgbaSourceBuffer,  // src vImage_Buffer  - interleaved 8-bit RGBA
    &yCbCrSourceBuffer, // dest vImage_Buffer - interleaved chunks Yp0 Cb0 Yp1 Cr0
    &infoARGBToYpCbCr,
    [3,0,1,2],          // RGBX --> XRGB
    vImage_Flags(kvImagePrintDiagnosticsToConsole))

/*
 Yp0    Cb0     Yp1    Cr0  |  Yp0    Cb0     Yp1    Cr0
 0xA9   0x5A    0x9F   0x9F |  0x9A   0x53    0x98   0x9F
 0x5E   0x5D    0x69   0x93 |  0x89   0x47    0xA7   0x97
 */
bufferPtr = yCbCrSourceBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

/// Create 2 blank vImage_Buffer objects
let yBuffer = try! vImage_Buffer(
    width: width,
    height: height,
    bitsPerPixel: 8)


let cbcrBuffer = try! vImage_Buffer(
    width: width/2,
    height: height,
    bitsPerPixel: 8*2)

_ = withUnsafePointer(to: yCbCrSourceBuffer) {
    (yCbCr: UnsafePointer<vImage_Buffer>) in
    withUnsafePointer(to: yBuffer) {
        (y: UnsafePointer<vImage_Buffer>) in
        withUnsafePointer(to: cbcrBuffer) {
            (cbCr: UnsafePointer<vImage_Buffer>) in
            var srcChannels = [
                UnsafeRawPointer(yCbCr.pointee.data),
                UnsafeRawPointer(yCbCr.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride)),
                UnsafeRawPointer(yCbCr.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride*2)),
                UnsafeRawPointer(yCbCr.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride*3))
            ]
            var destPlanarBuffers = [Optional(y), Optional(cbCr)]
            let channelCount = 2

            _ = vImageConvert_ChunkyToPlanar8(
                &srcChannels,
                &destPlanarBuffers,
                UInt32(channelCount),
                MemoryLayout<Pixel_8>.stride * channelCount,
                vImagePixelCount(width),
                vImagePixelCount(height),
                yCbCr.pointee.rowBytes,
                vImage_Flags(kvImageNoFlags))
        }
    }
}

/*
 Yp0    Yp1     Yp2    Yp3  |  Yp4    Yp5     Yp6    Y7
 0xA9   0x9F    0x9A   0x98 |  0x9A   0x9A    0x99   0x9C
 0x5E   0x69    0x89   0xA7 |  0xAF   0xA7    0x80   0x7E
 */
bufferPtr = yBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

// We cannot produce an instance of CGImage from `cbcrBuffer` (as of macOS 10.15).
// A custom function is called to create an instance of CIImage so that
// XCode playground can render it for a quick view.
// Colors are different from that rendered by the demo RGB2LumaChroma
let ciImage = createCIImage(from: cbcrBuffer, pixelFormat: .rg8Unorm)

/*
 Cb0    Cr0     Cb1    Cr1  |  Cb2    Cr2     Cb3    Cr3
 0x5A   0x9F    0x53   0x9F |  0x55   0xA0    0x54   0xA3
 0x5D   0x93    0x47   0x97 |  0x43   0x99    0x60   0x87
 */
bufferPtr = cbcrBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

/// Separate the CbCr pixels into two planes encapsulated in 2 vImage_Buffer objects.
let cbBuffer = try! vImage_Buffer(
    width: width/2,
    height: height,
    bitsPerPixel: 8)

let crBuffer = try! vImage_Buffer(
    width: width/2,
    height: height,
    bitsPerPixel: 8)

_ = withUnsafePointer(to: cbcrBuffer) {
    (cbCr: UnsafePointer<vImage_Buffer>) in
    withUnsafePointer(to: cbBuffer) {
        (cb: UnsafePointer<vImage_Buffer>) in
        withUnsafePointer(to: crBuffer) {
            (cr: UnsafePointer<vImage_Buffer>) in

            var srcChannels = [
                UnsafeRawPointer(cbCr.pointee.data),
                UnsafeRawPointer(cbCr.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride)),
            ]

            var destPlanarBuffers = [Optional(cb), Optional(cr)]
            let channelCount = 2

            _ = vImageConvert_ChunkyToPlanar8(
                &srcChannels,
                &destPlanarBuffers,
                UInt32(channelCount),
                MemoryLayout<Pixel_8>.stride * channelCount,
                vImagePixelCount(width/2),
                vImagePixelCount(height),
                cbCr.pointee.rowBytes,
                vImage_Flags(kvImageNoFlags))
        }
    }
}

/*
 Cb0    Cb1     Cb2    Cb3  |  Cb4    Cb5     Cb6    Cb7
 0x5A   0x53    0x55   0x54 |  0x52   0x53    0x4C   0x4E
 0x5D   0x47    0x43   0x60 |  0x76   0x75    0x73   0x73
 */
bufferPtr = cbBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()


/// The Chroma Blue Difference and Chroma Red Difference channels have the same height
// as the luminance channel but their widths are HALF the width of the luma channel.
var grayScaleImageFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 8,
    colorSpace: Unmanaged.passRetained(CGColorSpace(name: CGColorSpace.linearGray)!),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
    version: 0,
    decode: nil,
    renderingIntent: .defaultIntent)

let luminanceImage = try! yBuffer.createCGImage(format: grayScaleImageFormat)
let cbImage = try! cbBuffer.createCGImage(format: grayScaleImageFormat)
let crImage = try! crBuffer.createCGImage(format: grayScaleImageFormat)

print(yBuffer)
print(cbBuffer)
print(crBuffer)
print(cbcrBuffer)

/// To extract data from the 3 vImage_Buffers.
let lumaFrameSize = Int(yBuffer.height) * Int(yBuffer.width)
let chromaFrameSize = Int(cbBuffer.height) * Int(cbBuffer.width)
let buffers = [yBuffer, cbBuffer, crBuffer]

func mergeBuffers(_ buffers: [vImage_Buffer]) -> UnsafeMutableRawPointer? {
    let yPlane = malloc(lumaFrameSize)
    let uPlane = malloc(chromaFrameSize)
    let vPlane = malloc(chromaFrameSize)
    let planes = [yPlane, uPlane, vPlane]

    planes.withUnsafeBufferPointer {
        (destPlanes: UnsafeBufferPointer<UnsafeMutableRawPointer?>) -> Void in
        for index in stride(from: destPlanes.startIndex, to: destPlanes.endIndex, by: 1) {
            var destPointer = destPlanes[index]
            let width =  Int(buffers[index].width)
            let height = Int(buffers[index].height)
            let rowBytes = buffers[index].rowBytes
            var sourcePointer = buffers[index].data
            // Safer to copy row-by-row because the `rowBytes` property of each vImage_Buffer
            // might be equal or greater than its `width` property.
            for _ in 0 ..< height {
                memcpy(destPointer, sourcePointer, width)
                sourcePointer = sourcePointer! + rowBytes
                destPointer = destPointer! + width
            }
        }
    }

    // Merge the planes into a single memory block
    let bytes2Copy = [lumaFrameSize, chromaFrameSize, chromaFrameSize]
    let totalSize = lumaFrameSize + chromaFrameSize*2
    var memPtr = malloc(totalSize)
    let memoryBlock = memPtr            // Remember the start of the memory block
    for i in 0..<planes.count {
        let baseAddress = planes[i]
        memcpy(memPtr, baseAddress, bytes2Copy[i])
        memPtr = memPtr?.advanced(by: bytes2Copy[i])
    }
    free(yPlane)
    free(uPlane)
    free(vPlane)
    // Caller must free the memory block returned.
    return memoryBlock
}

let totalSize = lumaFrameSize + chromaFrameSize*2

let dataBlock = mergeBuffers(buffers)
// a) Write out the raw yuv data to a file
// b) To test the merged raw yuv file.
let directoryURL = playgroundSharedDataDirectory

let writeURL = directoryURL.appendingPathComponent(outputFilename)

let fileData =  Data(bytes: dataBlock!, count: totalSize)
try! fileData.write(to: writeURL, options: [])
dataBlock?.deallocate()

//: [Next](@next)
