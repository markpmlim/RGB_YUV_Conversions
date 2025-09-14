//: [Previous](@previous)

import Cocoa
import Accelerate.vImage
/*
 Remember to set the width and height correctly or this program will crash.
 Hibiscus422p: w=800, h=600
 PinkFlower422p: w=640, h=480
 test422p: w=640, h=640
 */
// Modify the following inputs:
let inputFilename = "Hibiscus422p"
let width = 800
let height = 600

/*
 
 iOS/macOS has no planar support for the following CVPixelBuffer pixel format (OSType).
 
 kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
 kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
 kCVPixelFormatType_422YpCbCr8Planar, and
 kCVPixelFormatType_422YpCbCr8PlanarFullRange
 
 are not available yet for macOS 10.15/iOS 13.0
 
 We have to convert the 3 separate y, u and v planes into a single yuv interleaved plane.
 
 Apple's Accelerate framework supports 2vuy conversion (kvImage422CbYpCrYp8).
 There is also support for yuvs/yuvf conversion (kvImage422YpCbYpCr8)
 
 The raw 422 planar file was created by ffmpeg using the commandline:
 
 ffmpeg -i sunflower.png  -pix_fmt yuv422p -vf "scale=640:640" test422p.yuv
 
 ffmpeg extracts the data and output 3 planes one after another.
 The first plane consists of luminance data, the 2nd plane chrominance blue data
 and the 3rd plane chrominance red data.
 */

// This function reads the raw 422yuv file and creates 3 vImage_Buffers.
func readYUV422(_ pathname: String, _ width: Int, _ height: Int) -> [vImage_Buffer]?
{
    let file = fopen(pathname, "rb")
    if file == nil {
        perror("Error opening file")
        return nil
    }
    
    // Calculate the size of y, u, and v planes
    let  frameSize = width * height
    let chromaSize = width/2 * height
    
    // Allocate memory for y, u, and v planes
    let yPlane = malloc(frameSize)
    let uPlane = malloc(chromaSize)
    let vPlane = malloc(chromaSize)
    
    if yPlane == nil || uPlane == nil || vPlane == nil {
        perror("Memory allocation failed");
        fclose(file)
        return nil
    }
    
    // Read the y plane
    fread(yPlane, 1, frameSize, file)
    // Read the u plane
    fread(uPlane, 1, chromaSize, file)
    // Read the v plane
    fread(vPlane, 1, chromaSize, file)

    let yBuffer = try! vImage_Buffer(width: width,
                                     height: height,
                                     bitsPerPixel: 8)
    // Possible bug: if the width is odd.
    let cbBuffer = try! vImage_Buffer(width: width/2,
                                      height: height,
                                      bitsPerPixel: 8)
    let crBuffer = try! vImage_Buffer(width: width/2,
                                      height: height,
                                      bitsPerPixel: 8)
    let buffers = [yBuffer, cbBuffer, crBuffer]
    let planes = [yPlane, uPlane, vPlane]
    
    buffers.withUnsafeBufferPointer {
        (destBuffers: UnsafeBufferPointer<vImage_Buffer>) -> Void in
        for index in stride(from: destBuffers.startIndex, to: destBuffers.endIndex, by: 1) {
            var destBuffer = destBuffers[index].data    // UnsafeMutableRawPointer
            let width =  Int(buffers[index].width)
            let height = Int(buffers[index].height)
            let rowBytes = buffers[index].rowBytes
            var sourceBytes = planes[index]             // UnsafeMutableRawPointer
            // Safer to copy row-by-row because the `rowBytes` property of each vImage_Buffer
            // is likely to be equal or greater than its `width` property.
            for _ in 0 ..< height {
                memcpy(destBuffer, sourceBytes, width)
                sourceBytes = sourceBytes! + width
                destBuffer = destBuffer! + rowBytes
            }
        }
    }
    // Clean up
    free(yPlane)
    free(uPlane)
    free(vPlane)
    fclose(file)

    return [yBuffer, cbBuffer, crBuffer]
}

/// Main code
guard let pathname = Bundle.main.path(forResource: inputFilename, 
                                      ofType: "yuv")
else {
    fatalError("File not found")
}


guard let srcBuffers = readYUV422(pathname, width, height)
else {
    fatalError("The array of source buffers is nil")
}

let  yBuffer = srcBuffers[0]
let cbBuffer = srcBuffers[1]
let crBuffer = srcBuffers[2]

var grayScaleImageFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 8,
    colorSpace: Unmanaged.passRetained(CGColorSpace(name: CGColorSpace.linearGray)!),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
    version: 0,
    decode: nil,
    renderingIntent: .defaultIntent)

// Check the buffers' data
/// The Chroma Blue Difference and Chroma Red Difference channels have the same height
// as the luminance channel but their widths are HALF the width of the luma channel.
let luminanceImage = try! yBuffer.createCGImage(format: grayScaleImageFormat)
let cbImage = try! cbBuffer.createCGImage(format: grayScaleImageFormat)
let crImage = try! crBuffer.createCGImage(format: grayScaleImageFormat)

////
let workBuffer = UnsafeMutablePointer<vImage_Buffer>.allocate(capacity: 2)
// prints "UnsafeMutablePointer<vImage_Buffer>"
// `pointee` should be a vImage_Buffer object
print(type(of: workBuffer))

workBuffer[0] = srcBuffers[1]
workBuffer[1] = srcBuffers[2]
let workBufferPtr: UnsafePointer<vImage_Buffer>? = UnsafePointer(workBuffer)
// prints "Optional<UnsafePointer<vImage_Buffer>>"
// `pointee` should be a vImage_Buffer object
print(type(of: workBufferPtr))

// `cbCrPlanarBuffers` is an array of source planar buffers encapulated in vImage_Buffer objects.
var cbCrPlanarBuffers = [workBufferPtr]
// prints "Array<Optional<UnsafePointer<vImage_Buffer>>>"
print(type(of: cbCrPlanarBuffers))

//// Interleave the 8-bit "pixels" from source buffers `cbBuffer` and `crBuffer` into the
//  destination buffer `cbCrBuffer`.
// The width of the `cbCrBuffer` is half that of the `yBuffer`
var cbCrBuffer = try! vImage_Buffer(width: width/2,
                                    height: height,
                                    bitsPerPixel: 8*2)

// All source buffers must have the same dimensions (width and height)
// but their `rowBytes` may be different.
_ = withUnsafePointer(to: cbBuffer) {
    (cb: UnsafePointer<vImage_Buffer>) in
    withUnsafePointer(to: crBuffer) {
        (cr: UnsafePointer<vImage_Buffer>) in
        withUnsafePointer(to: cbCrBuffer) {
            // `cbCrBuffer` is destination buffer
            (cbCr: UnsafePointer<vImage_Buffer>) in
            // source planar buffers are `cbBuffer` and `crBuffer`
            var cbCrPlanarBuffers = [Optional(cb), Optional(cr)]
            // `pointee` is a vImage_Buffer object
            var destChannels = [
                cbCr.pointee.data,
                cbCr.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride),
            ]

            /*
             The number of vImage buffer structures in the srcPlanarBuffers array and
             the number of channels in the destination image.
             */
            let channelCount = 2

            _ = vImageConvert_PlanarToChunky8(
                &cbCrPlanarBuffers,                             // srcPlanarBuffers
                &destChannels,
                UInt32(channelCount),
                MemoryLayout<Pixel_8>.stride * channelCount,    // destStrideBytes
                vImagePixelCount(width/2),                      // destWidth
                vImagePixelCount(height),                       // destHeight
                cbCr.pointee.rowBytes,                          // destRowBytes
                vImage_Flags(kvImageNoFlags))
        }
    }
}
// The `cbCrBuffer` vImage_Buffer object consists of interleaved chunks of CbCr "pixels"
//      {Cb0 Cr0} {Cb1 Cr1} {Cb2 Cr2} {Cb3 Cr3}

//// Combine the 16-bit "pixels" from `cbCrBuffer` with the 8-bit pixels of `yBuffer`

// First, ensure the `uvBuffer`  has the same dimensions as the `yBuffer`.
var uvBuffer =  try! vImage_Buffer(width: width,
                                   height: height,
                                   bitsPerPixel: 8)     // Note: not 8*2

// The `cbCrBuffer` was created with a `bitsPerPixel` parameter that is twice that
// of the `uvBuffer`. Their `rowBytes` should be the same.
// On the other hand, the `width` property is half that of `uvBuffer`.
// The memory size of their `data` properties should be equal.
memcpy(uvBuffer.data,
       cbCrBuffer.data,
       cbCrBuffer.rowBytes*height)

// Do a visual check to show data from `cbCrBuffer` have been copied to `uvBuffer`.
// Each chunk is 2 bytes.
var bufferPtr = uvBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 4 * 2 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

//// Interleave the 8-bit "pixels" from source buffers `uvBuffer` and `yBuffer` into the
//  destination buffer `yuvBuffer`.
var yuvBuffer = try! vImage_Buffer(width: width,
                                   height: height,
                                   bitsPerPixel: 8*2)

_ = withUnsafePointer(to: uvBuffer) {
    (uv: UnsafePointer<vImage_Buffer>) in
    withUnsafePointer(to: yBuffer) {
        (y: UnsafePointer<vImage_Buffer>) in
        withUnsafePointer(to: yuvBuffer) {
            (yuv: UnsafePointer<vImage_Buffer>) in

            var srcPlanarBuffers = [Optional(uv), Optional(y)]
            var destChannels = [
                yuv.pointee.data,
                yuv.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride),
            ]

            let channelCount = 2

            _ = vImageConvert_PlanarToChunky8(
                &srcPlanarBuffers,
                &destChannels,
                UInt32(channelCount),
                MemoryLayout<Pixel_8>.stride * channelCount,
                vImagePixelCount(width),
                vImagePixelCount(height),
                yuv.pointee.rowBytes,
                vImage_Flags(kvImageNoFlags))
        }
    }
}

// Note: the order of the chunks in `yuvBuffer` is Cb0 Yp0 Cr0 Yp1
// Each chunk is 4 bytes.
bufferPtr = yuvBuffer.data.assumingMemoryBound(to: UInt8.self)
for i in 0 ..< 2 * 4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

// Convert the 422CbYpCrYp8 source pixels to ARGB pixels.
func configureInfo() -> vImage_YpCbCrToARGB
{
    var info = vImage_YpCbCrToARGB()    // filled with zeroes
    
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
    // will be used by the function vImageConvert_422CbYpCrYp8ToARGB8888
    _ = vImageConvert_YpCbCrToARGB_GenerateConversion(
        kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
        &pixelRange,
        &info,
        kvImage422CbYpCrYp8,    // vImageYpCbCrType (OSType: 2vuy)
        kvImageARGB8888,        // vImageARGBType
        vImage_Flags(kvImageDoNotTile))
    
    return info
}

var infoYpCbCrToARGB = configureInfo()
var rgbaDestinationBuffer = try! vImage_Buffer(
    width: width,
    height: height,
    bitsPerPixel: 32)

// Cb0 Yp0 Cr0 Yp1  will be decoded as  A0 R0 G0 B0  A1 R1 G1 B1
var error = vImageConvert_422CbYpCrYp8ToARGB8888(
    &yuvBuffer,             // src
    &rgbaDestinationBuffer, // dest
    &infoYpCbCrToARGB,
    [1,2,3,0],              // XRGB -> RGBX
    255,
    vImage_Flags(kvImagePrintDiagnosticsToConsole))

// Check image is RGBA
bufferPtr = rgbaDestinationBuffer.data!.assumingMemoryBound(to: UInt8.self)
for i in 0..<2*4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

// Convert to an instance of CGImage in RGBA format.
var cgImageFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 8 * 4,
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))!
print(cgImageFormat.bitmapInfo) // 5

let cgImage = try! rgbaDestinationBuffer.createCGImage(format: cgImageFormat)

// Clean up
yBuffer.free()
cbBuffer.free()
crBuffer.free()
workBuffer.deallocate()
cbCrBuffer.free()
uvBuffer.free()
yuvBuffer.free()
rgbaDestinationBuffer.free()
/**/
//: [Next](@next)

