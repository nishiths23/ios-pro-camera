//
//  AVCoreViewController.swift
//  ProCamera
//
//  Created by Hao Wang on 3/10/15.
//  Copyright (c) 2015 Hao Wang. All rights reserved.
//

import UIKit
import AVFoundation
import AssetsLibrary
import CoreImage
import CoreGraphics
import Accelerate
import MediaPlayer

enum whiteBalanceMode {
    case Auto
    case Sunny
    case Cloudy
    case Temperature(Int)
    
    func getValue() -> Int {
        switch self {
        case .Temperature(let value):
            return value
        default:
            return -1
        }
    }
}

enum ISOMode {
    case Auto, Custom
}


extension Float {
    func format(f: String) -> String {
        return String(format: "%\(f)f", self)
    }
}


let histogramBuckets: Int = 16
let histogramCalcIntervalFrames = 10 //calc one histogram every X frames

class AVCoreViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    var initialized = false
    private let whiteBalanceModes = ["Auto", "Sunny", "Cloudy", "Manual"]
    private var capturedImage: UIImageView!
    private var videoDevice: AVCaptureDevice!
    private var captureSession: AVCaptureSession!
    private var stillImageOutput: AVCaptureStillImageOutput!
    private var videoDataOutput: AVCaptureVideoDataOutput!
    var previewLayer: AVCaptureVideoPreviewLayer!
    var flashOn = false
    var lastImage: UIImage?
    var frameImage: CGImage!
    var isoMode: ISOMode = ISOMode.Auto
    var exposureValue: Float = 0.5 // EV
    var currentISOValue: Float?
    var currentExposureDuration: Float64?
    var currentScale: CGFloat = 1.0
    var tempScale: CGFloat = 1.0
    var currentColorTemperature: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues!
    var histogramFilter: CIFilter?
    var _captureSessionQueue: DispatchQueue?
    var currentOutput: AVCaptureOutput!
    var useStillImageOutput = true // Must force to true in order to take photo
    var histogramDataImage: CIImage!
    var histogramDisplayImage: UIImage!
    var shootMode: Int! //0 = Auto, 1 = Tv, 2= Manual
    var lastHistogramEV: Double?
    var enableLastHistogramEV = false
    var EVMax: Float = 15.0
    var EVMaxAdjusted: Float = 15.0
    var gettingFrame: Bool = false
    var timer: DispatchSource!
    var histogramRaw: [Int] = Array(repeating: 0, count: histogramBuckets)
    var configLocked: Bool = false
    var currentHistogramFrameCount: Int = 0
    var photoQuality: NSNumber = 1.0 //From 0.0 to 1.0
    var usingJPEGOutput = true
    var obs: NSKeyValueObservation?
    
    // Some default settings
    let EXPOSURE_DURATION_POWER:Float = 4.0 //the exposure slider gain
    let EXPOSURE_MINIMUM_DURATION:Float64 = 1.0/2000.0
    
    deinit {
        obs = nil
    }
    
    func initialize() {
        if !initialized {
            histogramRaw.reserveCapacity(histogramBuckets)
            isoMode = .Auto
            _captureSessionQueue = DispatchQueue(__label: "capture_session_queue", attr: nil)
            _captureSessionQueue?.async {
                self.captureSession = AVCaptureSession()
                self.captureSession.sessionPreset = AVCaptureSession.Preset.photo
                self.videoDevice = AVCaptureDevice.default(for: AVMediaType.video) //default is back camera
                if let input = try? AVCaptureDeviceInput(device: self.videoDevice),
                self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    // @Discussion:
                    // Need AVCaptureVideoDataOutput for histogram
                    // AND
                    // AVCaptureStillImageOutput for photo capture
                    // CoreImage wants BGRA pixel format
                    let outputSettings: [String: Any] = [String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: Int(kCVPixelFormatType_32BGRA))]
                    self.videoDataOutput = AVCaptureVideoDataOutput()
                    self.videoDataOutput.videoSettings = outputSettings
                    self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self._captureSessionQueue)
                    
                    if self.captureSession.canAddOutput(self.videoDataOutput) {
                        self.captureSession.addOutput(self.videoDataOutput) //add Video output
                    }
                
                    self.stillImageOutput = AVCaptureStillImageOutput()
                    //using jpeg ourput
                    if self.usingJPEGOutput {
                        self.stillImageOutput.outputSettings = [AVVideoCodecKey: AVVideoCodecJPEG, AVVideoQualityKey: self.photoQuality]
                    } else {
                        //Try doing raw input
                        self.stillImageOutput.outputSettings = [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA]
                    }
                    
                    self.stillImageOutput.isHighResolutionStillImageOutputEnabled = true
                    self.currentOutput = self.stillImageOutput
                    
                    if self.captureSession.canAddOutput(self.stillImageOutput) {
                        self.captureSession.addOutput(self.stillImageOutput)
                        self.previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                        self.previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
                        self.previewLayer.connection?.videoOrientation = AVCaptureVideoOrientation.landscapeLeft
                        self.captureSession.startRunning()
                        self.initialized = true
                        DispatchQueue.main.async {
                            self.postInitilize()
                        }
                    }
                    return
                    //TODO: send notification
                }
            }
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let mediaType = CMFormatDescriptionGetMediaType(formatDesc)
            if (Int(mediaType) != kCMMediaType_Audio) {
                //video
                //calc histogram every X frames
                currentHistogramFrameCount += 1
                if currentHistogramFrameCount >= histogramCalcIntervalFrames,
                let imageBuffer: CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer){
                    //calc histogram
                    let sourceImage = CIImage(cvPixelBuffer: imageBuffer, options: nil)
                    self.calcHistogram(ciImage: sourceImage)
                    currentHistogramFrameCount = 0
                }
            }
        }
    }
    
    func runFilter(cameraImage: CIImage, filters: NSArray) -> CIImage? {
        var currentImage: CIImage?
        var activeInputs: [CIImage] = []
        
        for filter_i in filters {
            if let filter = filter_i as? CIFilter {
                filter.setValue(cameraImage, forKey: kCIInputImageKey)
                currentImage = filter.outputImage;
                if currentImage == nil {
                    return nil
                } else {
                    activeInputs.append(currentImage!)
                }
            }
        }
        
        if currentImage!.extent.isEmpty {
            return nil
        }
        return currentImage;
    }
    
    func postInitilize() {
        listenVolumeButton()
    }
    
    func lockConfig(complete: () -> ()) {
        if initialized {
            configLocked = true
            do {
                try videoDevice.lockForConfiguration()
                complete()
                videoDevice.unlockForConfiguration()
                self.postChangeCameraSetting()
                configLocked = false
            }catch {
                print("lockForConfiguration Failed \(error)")
            }
        }
    }
    
    func setWhiteBalanceMode(mode: whiteBalanceMode) {
        var wbMode: AVCaptureDevice.WhiteBalanceMode
        switch (mode) {
        case .Auto:
            wbMode = .continuousAutoWhiteBalance
        default:
            wbMode = .locked
        }
        let temperatureValue = mode.getValue()
        if (temperatureValue > -1) {
            //FixME: To add this feature
            //changeTemperatureRaw(Float(temperatureValue))
        }
        lockConfig { () -> () in
            if self.videoDevice.isWhiteBalanceModeSupported(wbMode) {
                self.videoDevice.whiteBalanceMode = wbMode;
            } else {
                print("White balance mode is not supported");
            }
        }
    }
    
    //value: Take a normalized Value
    func changeTemperature(_ value: Float) {
        if value > 1.0 {
            var x = 1.0
            x = x + 3.0
        }
        let mappedValue = value * 5000.0 + 3000.0 //map 0.0 - 1.0 to 3000 - 8000
        changeTemperatureRaw(mappedValue)
    }
    
    //Take the actual temperature value
    func changeTemperatureRaw(_ temperature: Float) {
        self.currentColorTemperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0.0)
        if initialized {
            setWhiteBalanceGains(gains: videoDevice.deviceWhiteBalanceGains(for: self.currentColorTemperature))
        }
    }
    
    // Normalize the gain so it does not exceed
    func normalizedGains(gains:AVCaptureDevice.WhiteBalanceGains) -> AVCaptureDevice.WhiteBalanceGains {
        var g = gains;
        g.redGain = max(1.0, g.redGain);
        g.greenGain = max(1.0, g.greenGain);
        g.blueGain = max(1.0, g.blueGain);
        
        g.redGain = min(videoDevice.maxWhiteBalanceGain, g.redGain);
        g.greenGain = min(videoDevice.maxWhiteBalanceGain, g.greenGain);
        g.blueGain = min(videoDevice.maxWhiteBalanceGain, g.blueGain);
        
        return g;
    }
    
    //Set the white balance gain
    func setWhiteBalanceGains(gains: AVCaptureDevice.WhiteBalanceGains) {
        lockConfig { () -> () in
            self.videoDevice.setWhiteBalanceModeLocked(with: self.normalizedGains(gains: gains), completionHandler: nil)
        }
    }
    
    // Available modes:
    // .Locked .AutoExpose .ContinuousAutoExposure .Custom
    func changeExposureMode(_ mode: AVCaptureDevice.ExposureMode) {
        lockConfig { () -> () in
            if self.videoDevice.isExposureModeSupported(mode) {
                self.videoDevice.exposureMode = mode
            }
        }
    }
    
    func changeExposureDuration(_ value: Float) {
        if initialized {
            let p = Float64(pow(value, EXPOSURE_DURATION_POWER)) // Apply power function to expand slider's low-end range
            let minDurationSeconds = Float64(max(CMTimeGetSeconds(videoDevice.activeFormat.minExposureDuration), EXPOSURE_MINIMUM_DURATION))
            let maxDurationSeconds = Float64(CMTimeGetSeconds(self.videoDevice.activeFormat.maxExposureDuration))
            let newDurationSeconds = Float64(p * (maxDurationSeconds - minDurationSeconds)) + minDurationSeconds // Scale from 0-1 slider range to actual duration
            
            if (videoDevice.exposureMode == .custom) {
                lockConfig { () -> () in
                    
                    if self.isoMode == .Auto {
                        // Going to calculate the correct exposure EV
                        // Keep EV stay the same
                        // Need to calculate the ISO based on current image exposure
                        // exposureTime * ISO = EV
                        // ISO from 29 to 464
                        // exposureTime from 1/8000 to 1/2
                        // Let's assume EV = 14.45
                        
                        //self.exposureValue = 14.45
                        self.currentISOValue = self.capISO(Float(self.exposureValue) / Float(newDurationSeconds))
                        //println("iso=\(self.currentISOValue) expo=\(newDurationSeconds)")
                    } else if self.currentISOValue == nil{
                        self.currentISOValue = AVCaptureDevice.currentISO
                    }
                    self.currentExposureDuration = newDurationSeconds
                    let newExposureTime = CMTimeMakeWithSeconds(Float64(newDurationSeconds), preferredTimescale: 1000*1000*1000)
                    self.videoDevice.setExposureModeCustom(duration: newExposureTime, iso: self.currentISOValue!, completionHandler: nil)
                }
            }
        } else {
            print("not initilized. changeExposureDuration Fail")
        }
    }
    
    //Only adjust max EV but does not chang EV value
    func adjustMaxEV() {
        // EV Mapping
        // 1/129 s = 0 - 15
        // 1/79 s = 0 - 25
        // 1/1999 = 0 - 0.902639
        //EV_max should be related to current exposure Duration
        let k: Float64 = (0.902639 - 25.0) / (1.0 / 1999.0 - 1.0 / 79.0)
        let b: Float64 = 25.0 - k / 79.0
        EVMaxAdjusted = Float(k * Float64(currentExposureDuration!) + b)
        print("currentExposureDuration \(String(describing: currentExposureDuration)) EVAdjusted=\(EVMaxAdjusted), EV= \(exposureValue)")
    }
    
    func zoomVideoOutput(scale: CGFloat) {
        tempScale = currentScale * scale
        tempScale = max(tempScale, 1.0)
        tempScale = min(tempScale, 4.0) //Max zoom 4x
        //This is for photo taken
        /*if let stillImageConnection = stillImageOutput!.connectionWithMediaType(AVMediaTypeVideo) {
            
            tempScale = min(tempScale, stillImageConnection.videoMaxScaleAndCropFactor)
            stillImageConnection.videoScaleAndCropFactor = tempScale
        }*/
        //this is for preview zoom
        /*println("currentScale=\(tempScale)")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        previewLayer.setAffineTransform(CGAffineTransformMakeScale(tempScale, tempScale))
        CATransaction.commit()
        */
        if videoDevice.responds(to: #selector(getter: AVCaptureDevice.videoZoomFactor)) && videoDevice.activeFormat.videoMaxZoomFactor > tempScale {
            lockConfig { () -> () in
                self.videoDevice.videoZoomFactor = self.tempScale
            }
        }
    }
    
    func changeEV(_ value: Float) {
        adjustMaxEV()
        exposureValue = value * EVMaxAdjusted
        
        
        //This is to try autoadjustEV based on histogram exposure. but doesn't seem to work well due to infinite feedback loop
        if lastHistogramEV != nil && self.enableLastHistogramEV {
            let evPercent = exposureValue / EVMax
            if lastHistogramEV! < 5000.0 && evPercent > 0.3 { //When EV is not too low but exposure is too low
                // Under Exposure. Make EV_max Larger
                exposureValue += Float(lastHistogramEV!) / 2500.0 // + from 0 to 10
            } else if lastHistogramEV! > 40000.0 && evPercent < 0.7 { //EV is not too high, but exposure is too high
                exposureValue *= 40000.0 / Float(lastHistogramEV!) //scale down
            }
        }
        
        if initialized && shootMode == 1 && self.isoMode == .Auto {
            //Need to auto adjust ISO
            self.currentISOValue = self.capISO(Float(exposureValue) / Float(currentExposureDuration!))
            lockConfig { () -> () in
                self.videoDevice.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: self.currentISOValue!, completionHandler: nil)
            }
        }
    }
    
    func getCurrentValueNormalized(_ name: String) -> Float! {
        var ret: Float = 0.5
        if name == "EV" {
            adjustMaxEV()
            ret = exposureValue / EVMaxAdjusted
        } else if name == "ISO" {
            if currentISOValue != nil {
                ret = (currentISOValue! - self.videoDevice.activeFormat.minISO) /  (self.videoDevice.activeFormat.maxISO - self.videoDevice.activeFormat.minISO)
            }
        } else if name == "SS"{ //shuttle speed
            let minDurationSeconds = Float64(max(CMTimeGetSeconds(videoDevice.activeFormat.minExposureDuration), EXPOSURE_MINIMUM_DURATION))
            let maxDurationSeconds = Float64(CMTimeGetSeconds(self.videoDevice.activeFormat.maxExposureDuration))
            if currentExposureDuration != nil {
                let val = Float((currentExposureDuration! - minDurationSeconds) / (maxDurationSeconds - minDurationSeconds))
                ret = Float(sqrt(sqrt(val))) // Apply reverse power
            }
        } else if name == "WB" { //White balance
            if self.currentColorTemperature != nil {
                print("WB currentval = \(currentColorTemperature.temperature)")
                ret = (currentColorTemperature.temperature - 3000.0) / 5000.0
            }
        }
        ret = min(ret, 1.0)
        ret = max(ret, 0.0)
        return ret
    }
    
    func capISO(_ value: Float) -> Float {
        if value > self.videoDevice.activeFormat.maxISO{
            return self.videoDevice.activeFormat.maxISO
        } else if value < self.videoDevice.activeFormat.minISO{
            return self.videoDevice.activeFormat.minISO
        }
        return value
    }
    
    func calcISOFromNormalizedValue(_ value: Float) -> Float {
        if initialized {
            var _value = value
            if _value > 1.0 {
                _value = 1.0
            }
            //map it to the proper iso value
            let minimumValue = self.videoDevice.activeFormat.minISO
            let maximumValue = self.videoDevice.activeFormat.maxISO
            let newValue = _value * (maximumValue - minimumValue) + minimumValue
            return newValue
        }
        return Float(0.0)
    }
    
    //input value from 0.0 to 1.0
    func changeISO(_ value: Float) {
        let newValue = calcISOFromNormalizedValue(value)
        lockConfig { () -> () in
            self.currentISOValue = newValue
            self.videoDevice.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: newValue, completionHandler: nil)
        }
    }
    
    func setFlashMode(on: Bool) {
        self.flashOn = on
    }
    
    func playShutterSound() {
        let path = Bundle.main.path(forResource: "shutter_sound", ofType: "mp3")
        let theAudio = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path!))
        theAudio?.prepareToPlay()
        theAudio?.volume = 1.0
        theAudio?.play()
    }
    
    @objc func takePhotoUsingStillImageOutput() {
        // Must be initialized
        if let videoConnection = currentOutput!.connection(with: AVMediaType.video) {
            videoConnection.videoOrientation = AVCaptureVideoOrientation.landscapeLeft
            stillImageOutput?.captureStillImageAsynchronously(from: videoConnection, completionHandler: {(buffer, error) in
                if let sampleBuffer = buffer {
                    if self.usingJPEGOutput,
                    let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(sampleBuffer),
                    let dataProvider = CGDataProvider(data: imageData as CFData),
                    let cgImageRef = CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent){
                        self.lastImage = UIImage(cgImage: cgImageRef, scale: 1.0, orientation: UIImage.Orientation.right)
                    } else {
                        //Raw ouput
                        
                    }
                    
                    //save to camera roll
                    if let image = self.lastImage {
                        self.beforeSavePhoto()
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        self.postSavePhoto()
                        //self.playShutterSound()
                        print("Take Photo")
                    }
                }
            })
        }
    }
    
    //save photo to camera roll
    func takePhoto() {
        if initialized {
            Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(takePhotoUsingStillImageOutput), userInfo: nil, repeats: false)
        } else {
            print("take photo failed. not initialized")
        }
    }
    
    func getFrame(complete: @escaping () -> ()) {
        if initialized && !self.gettingFrame {
            self._captureSessionQueue?.async {
                self.gettingFrame = true
                if let videoConnection = self.currentOutput!.connection(with: AVMediaType.video) {
                    videoConnection.videoOrientation = AVCaptureVideoOrientation.portrait
                    if self.useStillImageOutput {
                        self.stillImageOutput?.captureStillImageAsynchronously(from:videoConnection, completionHandler: {(buffer, error) in
                            if let sampleBuffer = buffer,
                            let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(sampleBuffer),
                            let dataProvider = CGDataProvider(data: imageData as CFData){
                                self.frameImage = CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                                complete()
                                self.gettingFrame = false
                            }
                        })
                    } else {
                        //using videoDataOutput
                    }
                    self.gettingFrame = false
                }
                self.gettingFrame = false
            }
        }
    }
    
    //Deprecated.
    func startTimer() {
        let queue = DispatchQueue(__label: "com.procam.timer", attr: nil)
        timer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: 0), queue: queue) as? DispatchSource
        if let timer = self.timer {
            timer.schedule(deadline: .now(), repeating: DispatchTimeInterval.seconds(5), leeway: DispatchTimeInterval.seconds(1)) // every 5 seconds, with leeway of 1 second
            timer.setEventHandler {
                if !self.configLocked {
                    //self.calcHistogram()
                }
            }
            timer.resume()
        }
    }
    
    func stopTimer() {
        timer.cancel()
        timer = nil
    }
    
    // scaleDiv = divide by Int
    func scaleDownCGImage(image: CGImage, scale: Float) -> CGImage?{
        let scaleDiv = (1.0 / scale)
        let width = Float(image.width) / scaleDiv
        let height = Float(image.height) / scaleDiv
        let bitsPerComponent = image.bytesPerRow
        let bytesPerRow = image.bytesPerRow
        guard let colorSpace = image.colorSpace else { return nil }
        let bitmapInfo = image.bitmapInfo
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        context.interpolationQuality = .medium
        let imgSize = CGSize(width: Int(width), height: Int(height))
        context.draw(image, in: CGRect(origin: .zero, size: imgSize))
        //println("scaled image for histogram calc \(imgSize)")
        return context.makeImage()
    }
    
    func calcHistogram(ciImage: CIImage!) {
        if initialized {
            self._captureSessionQueue?.async {
                if ciImage != nil {
                    /* //Was trying to use a filter but doesn't work out
                    let params: NSDictionary = [
                        String(kCIInputImageKey): ciImage,
                        String(kCIInputExtentKey): CIVector(CGRect: ciImage.extent()),
                        "inputCount": 256
                    ]
                    self.histogramFilter = CIFilter(name: "CIAreaHistogram", withInputParameters: params)

                    self.histogramDataImage = self.histogramFilter!.outputImage
                    */
                    
                    self.getHistogramRaw(dataImage: ciImage)
                    DispatchQueue.main.async {
                        self.postCalcHistogram()
                    }
                }
            }
        }
    }
    
    func convertCIImageToCGImage(inputImage: CIImage) -> CGImage? {
        let context = CIContext(options: nil)
        return context.createCGImage(inputImage, from: inputImage.extent)
    }
    
    func getHistogramRaw(dataImage: CIImage) {
        guard let image = convertCIImageToCGImage(inputImage: dataImage),
        let cgImage = scaleDownCGImage(image: image, scale: 0.5),
        let imageData: CFData = cgImage.dataProvider?.data else { return }
        let dataInput: UnsafePointer<UInt8> = CFDataGetBytePtr(imageData)
        let dataInputMutable = UnsafeMutableRawPointer(mutating: dataInput)
        var vImageBuffer = vImage_Buffer(data: dataInputMutable, height: UInt(cgImage.height), width: UInt(cgImage.width), rowBytes: cgImage.bytesPerRow)
        
        let alpha = [UInt](repeating: 0, count: 256)
        let red = [UInt](repeating: 0, count: 256)
        let green = [UInt](repeating: 0, count: 256)
        let blue = [UInt](repeating: 0, count: 256)

        let a = UnsafeMutablePointer<vImagePixelCount>(mutating: alpha) as UnsafeMutablePointer<vImagePixelCount>?
        let r = UnsafeMutablePointer<vImagePixelCount>(mutating: red) as UnsafeMutablePointer<vImagePixelCount>?
        let g = UnsafeMutablePointer<vImagePixelCount>(mutating: green) as UnsafeMutablePointer<vImagePixelCount>?
        let b = UnsafeMutablePointer<vImagePixelCount>(mutating: blue) as UnsafeMutablePointer<vImagePixelCount>?

        let rgba = [r, g, b, a]

        let histogram = UnsafeMutablePointer<UnsafeMutablePointer<vImagePixelCount>?>(mutating: rgba)
        let error:vImage_Error = vImageHistogramCalculation_ARGB8888(&vImageBuffer, histogram, 0);
        
        if (error == kvImageNoError) {
            let pixCountRefNum: Double = 1.0
            var totalExpoVal = 0.0
            //clear histogramRaw
            histogramRaw = Array(repeating: 0, count: histogramBuckets)
            for j in 0..<256 {
                if let red = histogram[0]?[j],
                let green = histogram[1]?[j],
                let blue = histogram[2]?[j] {
                    let currentVal = Double(red + green + blue) / pixCountRefNum
                    if currentVal > 0 {
                        //find out which bucket it is in
                        let bucketNum = j / histogramBuckets
                        histogramRaw[bucketNum] += Int(currentVal)
                        //println("j=\(j),\(currentVal)")
                        if self.enableLastHistogramEV {
                            totalExpoVal += currentVal * Double(j)
                        }
                    }
                }
            }
            //println("totalExpoVal=\(totalExpoVal)")
            if self.enableLastHistogramEV {
                lastHistogramEV = totalExpoVal
            }
            //delloc
            r?.deallocate()
            g?.deallocate()
            b?.deallocate()
            a?.deallocate()
            histogram.deallocate()
        } else {
            print("Histogram vImage error: \(error)")
        }
    }
    
    func processHistogram() {
        
    }
    
    func generateHistogramImageFromDataImage(dataImage: CIImage) -> UIImage! {
        let context = CIContext(options: nil)
        let params : [String: Any] = [String(kCIInputImageKey): dataImage]
        guard let filter = CIFilter(name: "CIHistogramDisplayFilter", parameters: params),
        let outputImage = filter.outputImage
        else { return nil }
        
        let outExtent = outputImage.extent
        if let cgImage = context.createCGImage(outputImage, from: outExtent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
    
    func postCalcHistogram() {
        
    }


    
    
    func applyFilter(image: CIImage) {
        let filter = CIFilter(name: "CISepiaTone")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(0.8, forKey: kCIInputIntensityKey)
        if let result = filter?.value(forKey: kCIOutputImageKey) as? CIImage {
            _ = result.extent
        }
    }
    
    func beforeSavePhoto() {
        
    }
    
    func postSavePhoto() {
        
    }
    
    func postChangeCameraSetting() {
        
    }
    
    func FloatToDenominator(value: Float) -> Int {
        if value > 0.0 {
            let denominator = 1.0 / value
            return Int(denominator)
        }
        return 0
    }
    
    func listenVolumeButton(){
        let audioSession = AVAudioSession.sharedInstance()
        obs = audioSession.observe( \.outputVolume ) { (av, change) in
            self.takePhoto()
        }
        do {
            try audioSession.setActive(true)
        } catch { return }
        audioSession.addObserver(self, forKeyPath: "outputVolume",
            options: NSKeyValueObservingOptions.new, context: nil)
        //hide volumn view
        let rect = CGRect(x: -500.0, y: -500.0, width: 0, height: 0)
        let volumeView: MPVolumeView = MPVolumeView(frame: rect)
        view.addSubview(volumeView)
    }
    
    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

}
