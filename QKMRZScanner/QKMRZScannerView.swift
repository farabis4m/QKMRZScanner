//
//  QKMRZScannerView.swift
//  QKMRZScanner
//
//  Created by S on 03/10/2018.
//

import UIKit
import AVFoundation
import TesseractOCR
import QKMRZParser
import QKGPUImage2

public protocol QKMRZScannerViewDelegate: class {
    func mrzScannerView(_ mrzScannerView: QKMRZScannerView, didFind scanResult: QKMRZScanResult)
}

@IBDesignable
public class QKMRZScannerView: UIView {
    fileprivate var tesseract: G8Tesseract!
    fileprivate let mrzParser = QKMRZParser(ocrCorrection: true)
    fileprivate let captureSession = AVCaptureSession()
    fileprivate let videoOutput = AVCaptureVideoDataOutput()
    fileprivate let videoPreviewLayer = AVCaptureVideoPreviewLayer()
    fileprivate let ciContext = CIContext()
    fileprivate let cutoutView = QKCutoutView()
    public weak var delegate: QKMRZScannerViewDelegate?
    
    fileprivate var interfaceOrientation: UIInterfaceOrientation {
        return UIApplication.shared.statusBarOrientation
    }
    
    // MARK: Initializers
    override public init(frame: CGRect) {
        super.init(frame: frame)
        setViewStyle()
        setupCaptureSession()
        addCutoutView()
        initTesseract()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setViewStyle()
        setupCaptureSession()
        addCutoutView()
        initTesseract()
    }
    
    // MARK: Overriden methods
    override public func prepareForInterfaceBuilder() {
        setViewStyle()
        addCutoutView()
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        adjustVideoPreviewLayerFrame()
    }
    
    // MARK: AVCaptureSession
    fileprivate func setupCaptureSession() {
        captureSession.sessionPreset = .high
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Camera not accessible")
            return
        }
        
        guard let deviceInput = try? AVCaptureDeviceInput(device: camera) else {
            print("Capture input could not be initialized")
            return
        }
        
        if captureSession.canAddInput(deviceInput) && captureSession.canAddOutput(videoOutput) {
            captureSession.addInput(deviceInput)
            captureSession.addOutput(videoOutput)
            
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "video_frames_queue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem))
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.connection(with: .video)!.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
            
            videoPreviewLayer.session = captureSession
            videoPreviewLayer.videoGravity = .resizeAspectFill
            
            layer.insertSublayer(videoPreviewLayer, at: 0)
            startCaptureSession()
        }
        else {
            print("Input & Output could not be added to the session")
        }
    }
    
    fileprivate func startCaptureSession() {
        DispatchQueue.global(qos: .userInitiated).async { [unowned self] in
            self.captureSession.startRunning()
            DispatchQueue.main.async { self.adjustVideoPreviewLayerFrame() }
        }
    }
    
    // MARK: MRZ
    fileprivate func mrz(from cgImage: CGImage) -> QKMRZResult? {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let mrzRegionHeight = (imageHeight * 0.25) // MRZ occupies roughly 25% of the document's height
        let croppingRect = CGRect(origin: CGPoint(x: 0, y: (imageHeight - mrzRegionHeight)), size: CGSize(width: imageWidth, height: mrzRegionHeight))
        let mrzRegionImage = UIImage(cgImage: cgImage.cropping(to: croppingRect)!)
        
        tesseract.image = mrzRegionImage
        tesseract.recognize()
        
        if let mrzLines = mrzLines(from: tesseract.recognizedText) {
            return mrzParser.parse(mrzLines: mrzLines)
        }
        
        return nil
    }
    
    fileprivate func mrzLines(from recognizedText: String) -> [String]? {
        let mrzString = recognizedText.replacingOccurrences(of: " ", with: "")
        var mrzLines = mrzString.components(separatedBy: "\n").filter({ !$0.isEmpty })
        
        // Remove garbage strings located at the beginning and at the end of the result
        if !mrzLines.isEmpty {
            let averageLineLength = (mrzLines.reduce(0, { $0 + $1.count }) / mrzLines.count)
            mrzLines = mrzLines.filter({ $0.count >= averageLineLength })
        }
        
        return mrzLines.isEmpty ? nil : mrzLines
    }
    
    // MARK: Document Image from Photo cropping
    fileprivate func cutoutRect(for cgImage: CGImage) -> CGRect {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let rect = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: cutoutView.cutoutRect)
        let videoOrientation = videoPreviewLayer.connection!.videoOrientation
        
        if videoOrientation == .portrait || videoOrientation == .portraitUpsideDown {
            return CGRect(x: (rect.minY * imageWidth), y: (rect.minX * imageHeight), width: (rect.height * imageWidth), height: (rect.width * imageHeight))
        }
        else {
            return CGRect(x: (rect.minX * imageWidth), y: (rect.minY * imageHeight), width: (rect.width * imageWidth), height: (rect.height * imageHeight))
        }
    }
    
    fileprivate func documentImage(from cgImage: CGImage) -> CGImage {
        let croppingRect = cutoutRect(for: cgImage)
        return cgImage.cropping(to: croppingRect)!
    }
    
    fileprivate func enlargedDocumentImage(from cgImage: CGImage) -> UIImage {
        var croppingRect = cutoutRect(for: cgImage)
        let margin = (0.05 * croppingRect.height) // 5% of the height
        croppingRect = CGRect(x: (croppingRect.minX - margin), y: (croppingRect.minY - margin), width: croppingRect.width + (margin * 2), height: croppingRect.height + (margin * 2))
        return UIImage(cgImage: cgImage.cropping(to: croppingRect)!)
    }
    
    // MARK: Misc
    fileprivate func setViewStyle() {
        backgroundColor = .black
    }
    
    fileprivate func adjustVideoPreviewLayerFrame() {
        videoOutput.connection(with: .video)?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.connection?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.frame = bounds
    }
    
    fileprivate func addCutoutView() {
        cutoutView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cutoutView)
        
        NSLayoutConstraint.activate([
            cutoutView.topAnchor.constraint(equalTo: topAnchor),
            cutoutView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cutoutView.leftAnchor.constraint(equalTo: leftAnchor),
            cutoutView.rightAnchor.constraint(equalTo: rightAnchor)
        ])
    }
    
    fileprivate func initTesseract() {
        let bundlePath = Bundle(for: type(of: self)).bundlePath
        let config = [
            kG8ParamLoadSystemDawg: "F",
            kG8ParamLoadFreqDawg: "F",
            kG8ParamLoadNumberDawg: "F",
            kG8ParamLoadPuncDawg: "F",
            kG8ParamLoadUnambigDawg: "F",
            kG8ParamLoadBigramDawg: "F",
            kG8ParamWordrecEnableAssoc: "F",
            kG8ParamTesseditCharWhitelist: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ<"
        ]
        
        tesseract = G8Tesseract(language: "ocrb", configDictionary: config, configFileNames: [], absoluteDataPath: bundlePath, engineMode: .tesseractOnly, copyFilesFromResources: false)!
        tesseract.pageSegmentationMode = .singleBlock
        tesseract.delegate = self
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension QKMRZScannerView: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)!
        let documentImage = self.documentImage(from: cgImage)
        
        if let mrzResult = mrz(from: documentImage), mrzResult.allCheckDigitsValid {
            captureSession.stopRunning()
            
            DispatchQueue.main.async {
                let enlargedDocumentImage = self.enlargedDocumentImage(from: cgImage)
                let scanResult = QKMRZScanResult(mrzResult: mrzResult, documentImage: enlargedDocumentImage)
                self.delegate?.mrzScannerView(self, didFind: scanResult)
            }
        }
    }
}

// MARK: - G8TesseractDelegate
extension QKMRZScannerView: G8TesseractDelegate {
    public func preprocessedImage(for tesseract: G8Tesseract, sourceImage: UIImage) -> UIImage {
        let resampling = LanczosResampling()
        let saturation = SaturationAdjustment()
        let contrast = ContrastAdjustment()
        let adaptiveThreshold = AdaptiveThreshold()
        let medianFilter = MedianFilter()
        let blur = GaussianBlur()
        let imageSizeRatio = Float(sourceImage.size.height / sourceImage.size.width)
        
        resampling.overriddenOutputSize = Size(width: 1000, height: (imageSizeRatio * 1000))
        saturation.saturation = 0
        contrast.contrast = 2
        adaptiveThreshold.blurRadiusInPixels = 4
        blur.blurRadiusInPixels = 1
        
        return sourceImage.filterWithPipeline({ input, output in
            input --> resampling --> saturation --> contrast --> adaptiveThreshold --> medianFilter --> blur --> output
        })
    }
}
