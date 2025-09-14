//: [Previous](@previous)

import Foundation
import Accelerate.vImage

/*
 Remember to set the width and height correctly or this program will crash.
 Hibiscus444p: w=800, h=600
 PinkFlower444p: w=640, h=480
 test444p: w=640, h=640
 */
// Modify the following inputs:
let inputFilename = "test444p"
let width = 640
let height = 640

/*
 iOS/macOS has no planar support for the following CVPixelBuffer pixel format (OSType)
 
 kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
 kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
 kCVPixelFormatType_444YpCbCr8Planar, and,
 kCVPixelFormatType_444YpCbCr8PlanarFullRange
 
 are not available for macOS 10.15/iOS 13.0
 
 We have to convert the 3 separate y, u and v planes into a single yuv interleaved plane.
 
 Apple's Accelerate framework supports kvImage444CrYpCb8 (v308) conversion.
 There is also support for kvImage444CbYpCrA8 (v408).
 
 The raw 444 planar file was created by ffmpeg using the commandline:
 
 ffmpeg -i sunflower.png  -pix_fmt yuv444p -vf "scale=640:640" test444p.yuv
 
 ffmpeg extracts the bytes and output the data of 3 planes one after another.
 The first plane consists of luminance data, the 2nd plane chrominance blue data
 and the 3rd plane chrominance red data.
 */

// This function reads the raw 444yuv file and creates 3 vImage_Buffers.
func readYUV444(_ url: URL, _ width: Int, _ height: Int) -> [vImage_Buffer]?
{
    var fileData: Data? = nil
    do {
        fileData = try Data(contentsOf: url, options: [])
    }
    catch let err {
        print(err)
        return nil
    }

    // Calculate the size of y, u, and v planes
    let  frameSize = width * height         // This is also the size of the luminance plane
    let chromaSize = width * height
    
    // Allocate memory for y, u, and v planes
    guard let yPlane = malloc(frameSize)    // UnsafeMutableRawPointer
    else {
        return nil
    }
    guard let uPlane = malloc(chromaSize)
    else {
        return nil
    }
    guard let vPlane = malloc(chromaSize)
    else {
        return nil
    }

    // Read the y plane
    var range: Range = 0..<frameSize
    var destPointer = yPlane.assumingMemoryBound(to: UInt8.self)    // UnsafeMutablePointer<UInt8>
    fileData!.copyBytes(to: destPointer, from: range)
    // Read the u plane
    range = frameSize..<(frameSize+chromaSize)
    destPointer = uPlane.assumingMemoryBound(to: UInt8.self)
    fileData!.copyBytes(to: destPointer, from: range)
    // Read the v plane
    range = (frameSize+chromaSize)..<(frameSize+chromaSize*2)
    destPointer = vPlane.assumingMemoryBound(to: UInt8.self)
    fileData!.copyBytes(to: destPointer, from: range)

    let yBuffer = try! vImage_Buffer(width: width,
                                     height: height,
                                     bitsPerPixel: 8)
    let cbBuffer = try! vImage_Buffer(width: width,
                                      height: height,
                                      bitsPerPixel: 8)
    let crBuffer = try! vImage_Buffer(width: width,
                                      height: height,
                                      bitsPerPixel: 8)
    let buffers = [yBuffer, cbBuffer, crBuffer]
    let planes = [yPlane, uPlane, vPlane]

    buffers.withUnsafeBufferPointer {
        (destBuffers: UnsafeBufferPointer<vImage_Buffer>) -> Void in
        for index in stride(from: destBuffers.startIndex, to: destBuffers.endIndex, by: 1) {
            var destBuffer = destBuffers[index].data    // type: UnsafeMutableRawPointer
            let width =  Int(buffers[index].width)
            let height = Int(buffers[index].height)
            let rowBytes = buffers[index].rowBytes
            var sourceBytes = planes[index]             // type: UnsafeMutableRawPointer
            // Safer to copy row-by-row because the `rowBytes` property of each vImage_Buffer
            // is likely to be equal or greater than its `width` property.
            for _ in 0 ..< height {
                memcpy(destBuffer, sourceBytes, width)
                sourceBytes = sourceBytes + width
                destBuffer = destBuffer! + rowBytes
            }
        }
    }
    // Clean up
    free(yPlane)
    free(uPlane)
    free(vPlane)
    
    return [yBuffer, cbBuffer, crBuffer]
}

//// Main code
guard let pathURL = Bundle.main.url(forResource: inputFilename,
                                    withExtension: "yuv")
else {
    fatalError("File not found")
}

guard let srcBuffers = readYUV444(pathURL, width, height)
else {
    fatalError("The array of source buffers is nil")
}

let  yBuffer = srcBuffers[0]
let cbBuffer = srcBuffers[1]
let crBuffer = srcBuffers[2]

//// Interleave the 8-bit "pixels" from source buffers `yBuffer`, ``cbBuffer and `crBuffer`
//  into the destination buffer `yCbCrBuffer`.
var yCbCrBuffer = try! vImage_Buffer(width: width,
                                     height: height,
                                     bitsPerPixel: 8*3)

// All source buffers must have the same dimensions (width and height)
// but their `rowBytes` may be different.
_ = withUnsafePointer(to: crBuffer) {
    (cr: UnsafePointer<vImage_Buffer>) in
    withUnsafePointer(to: yBuffer) {
        (y: UnsafePointer<vImage_Buffer>) in
        withUnsafePointer(to: cbBuffer) {
            (cb: UnsafePointer<vImage_Buffer>) in
            withUnsafePointer(to: yCbCrBuffer) {
                (yCbCr: UnsafePointer<vImage_Buffer>) in
                // order is important
                var srcPlanarBuffers = [Optional(cr), Optional(y), Optional(cb)]
                var destChannels = [
                    yCbCr.pointee.data,
                    yCbCr.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride),
                    yCbCr.pointee.data.advanced(by: MemoryLayout<Pixel_8>.stride*2)
                ]
                /*
                 The number of vImage buffer structures in the srcPlanarBuffers array and
                 the number of channels in the destination image.
                 */
                let channelCount = 3

                _ = vImageConvert_PlanarToChunky8(
                        &srcPlanarBuffers,
                        &destChannels,
                        UInt32(channelCount),
                        MemoryLayout<Pixel_8>.stride * channelCount,    // destStrideBytes
                        vImagePixelCount(width),
                        vImagePixelCount(height),
                        yCbCr.pointee.rowBytes,                         // destRowBytes
                        vImage_Flags(kvImageNoFlags))
            }
        }
    }
}

// Interleaved CrYpCb chunks
// {Cr0 Yp0 Cb0}, {Cr1 Yp1 Cb0}
var bufferPtr = yCbCrBuffer.data!.assumingMemoryBound(to: UInt8.self)
for i in 0..<3*4 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

// Convert the yCbCr pixels to ARGB
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
    // will be used by the function vImageConvert_444CrYpCb8ToARGB8888
    _ = vImageConvert_YpCbCrToARGB_GenerateConversion(
        kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
        &pixelRange,
        &info,
        kvImage444CrYpCb8,      // vImageYpCbCrType (OSType:v308)
        kvImageARGB8888,        // vImageARGBType
        vImage_Flags(kvImageDoNotTile))

    return info
}

var infoYpCbCrToARGB = configureInfo()
var rgbaDestinationBuffer = try! vImage_Buffer(
    width: width,
    height: height,
    bitsPerPixel: 32)
//print(rgbaDestinationBuffer)

// Note: the order which is Cr Yp Cb
// Cr Yp Cb will be decoded as R G B A
var error = vImageConvert_444CrYpCb8ToARGB8888(
    &yCbCrBuffer,           // src
    &rgbaDestinationBuffer, // dest
    &infoYpCbCrToARGB,
    [1,2,3,0],              // XRGB -> RGBX
    255,
    vImage_Flags(kvImagePrintDiagnosticsToConsole))

// Check image is RGBA
bufferPtr = rgbaDestinationBuffer.data!.assumingMemoryBound(to: UInt8.self)
for i in 0..<8 {
    print(String(format: "0x%02X", bufferPtr[i]), terminator: " ")
}
print()

// Setup for a visual check by creating an instance of CGImage.
var cgImageFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 8 * 4,
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))!
//cgImageFormat.bitmapInfo    // 5
let cgImage = try! rgbaDestinationBuffer.createCGImage(format: cgImageFormat)

yBuffer.free()
cbBuffer.free()
crBuffer.free()
yCbCrBuffer.free()
rgbaDestinationBuffer.free()

//: [Next](@next)
