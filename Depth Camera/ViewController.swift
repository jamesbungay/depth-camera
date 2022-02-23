//
//  ViewController.swift
//  Depth Camera
//
//  Created by James Bungay on 25/10/2021.
//  Copyright © 2021 James Bungay. All rights reserved.
//

import UIKit
import AVFoundation
import Photos
import Accelerate

class ViewController: UIViewController, AVCaptureDepthDataOutputDelegate {
    
    private let captureSession = AVCaptureSession()
    
    private let photoOutput = AVCapturePhotoOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    
    // Communicate with the session and other session objects on this queue.
    private let sessionQueue = DispatchQueue(label: "session queue", attributes: [], autoreleaseFrequency: .workItem)
    
    // Depth data handled on this synchronous queue.
    private let dataOutputQueue = DispatchQueue(label: "video data queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)

    private var videoDeviceInput: AVCaptureDeviceInput!
    
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera],
                                                                               mediaType: .video,
                                                                               position: .front)
    
    
    @IBOutlet weak var cameraPreviewView: CameraPreviewView!
    
    @IBOutlet weak var captureButton: UIButton!
    
    @IBOutlet weak var depthLabel: UILabel!
    
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    private var waitingToShowDepth = false
    
    
    private let depthMeasurementRepeats = 10
    private var depthMeasurementsLeftInLoop = 0
    private var depthMeasurementsCumul: Float32 = 0.0
    private var depthMeasurementMin: Float32 = 0.0
    private var depthMeasurementMax: Float32 = 0.0
    private var depthMeasurementsString = ""
    
    
    // MARK: ViewController Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        if PHPhotoLibrary.authorizationStatus() == .notDetermined {
            PHPhotoLibrary.requestAuthorization({_ in })
        }
        
        // Verify authorisation for video capture, and then set up captureSession:
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized || AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            sessionQueue.async {
                self.setUpCaptureSession()
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        
        // If unauthorised for video capture, display an alert explaining why:
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied: // The user has previously denied access.
                showAlert(title: "No camera access", msg: "Please allow camera access in settings for Tremor Camera to use this app.")
                return
            case .restricted: // The user can't grant access due to restrictions.
                showAlert(title: "No camera access", msg: "Your parental restrictions prevent you from using the camera. Camera access is needed to use this app.")
                return
            default:
                return
        }
    }
    
    
    // MARK: Capture Session Setup
    
    func setUpCaptureSession() {
        
        print("ofijfoij")
        
        // Setup camera input to captureSession:
        let defaultVideoDevice: AVCaptureDevice? = videoDeviceDiscoverySession.devices.first
        
        guard let videoDevice = defaultVideoDevice else {
            print("Could not find any video device")
            return
        }
        
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            print("Could not create video device input: \(error)")
            return
        }
//        guard let videoDevice = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
//            else { return }  // Configuration failed, no true depth camera.
//
//        guard let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice)
//            else { return }  // Configuration failed, cannot use camera as capture input device.
//
        
        captureSession.beginConfiguration()
        
        self.captureSession.sessionPreset = AVCaptureSession.Preset.vga640x480
        
        // Add video input:
        if captureSession.canAddInput(videoDeviceInput) {
            captureSession.addInput(videoDeviceInput)
        } else { return }  // Configuration failed, cannot add input to captureSession.
        
        
        // Add photo output:
        guard self.captureSession.canAddOutput(photoOutput)
            else { fatalError("Can't add photo output.") }
        self.captureSession.addOutput(photoOutput)
        
        
        // Add depth data output:
        if captureSession.canAddOutput(depthDataOutput) {
            captureSession.addOutput(depthDataOutput)
            depthDataOutput.isFilteringEnabled = false
            if let connection = depthDataOutput.connection(with: .depthData) {
                connection.isEnabled = true
            } else {
                print("No AVCaptureConnection")
            }
        } else {
            print("Could not add depth data output to the session")
            return
        }
        depthDataOutput.setDelegate(self, callbackQueue: dataOutputQueue)
        
        
        // Search for highest resolution with half-point depth values:
        let depthFormats = videoDevice.activeFormat.supportedDepthDataFormats
        let filtered = depthFormats.filter({
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
        })
        let selectedFormat = filtered.max(by: {
            first, second in CMVideoFormatDescriptionGetDimensions(first.formatDescription).width < CMVideoFormatDescriptionGetDimensions(second.formatDescription).width
        })
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeDepthDataFormat = selectedFormat
            videoDevice.unlockForConfiguration()
        } catch {
            print("Could not lock device for configuration: \(error)")
            return
        }
        
        captureSession.commitConfiguration()  // Must be called after completing capture session configuration

        // Set up preview for captureSession:
        DispatchQueue.main.async {
            self.cameraPreviewView.videoPreviewLayer.session = self.captureSession
            self.cameraPreviewView.videoPreviewLayer.videoGravity = .resizeAspect  // Set video preview to fit the view with no overflow
        }

        sessionQueue.async {
            self.captureSession.startRunning()
        }
    }

    
    // MARK: Depth data delegate
    
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        
        if waitingToShowDepth {
            
            if depthMeasurementsLeftInLoop == 0 {
                depthMeasurementsCumul = 0.0
                depthMeasurementMin = 9999.9
                depthMeasurementMax = 0.0
                depthMeasurementsLeftInLoop = depthMeasurementRepeats
                depthMeasurementsString = ""
                
                DispatchQueue.main.async {
                    self.depthLabel.isHidden = true
                    self.activityIndicator.isHidden = false
                }
            }
            
            if depthMeasurementsLeftInLoop > 0 {
                let depthFrame = depthData.depthDataMap

                let depthPoint = CGPoint(x: CGFloat(CVPixelBufferGetWidth(depthFrame)) / 2, y: CGFloat(CVPixelBufferGetHeight(depthFrame) / 2))
                
//                print(depthPoint)
                
                
        //      MAGIC FUNCTION WHICH GETS DEPTH VALUE FROM POINT:
                
                assert(kCVPixelFormatType_DepthFloat16 == CVPixelBufferGetPixelFormatType(depthFrame))
                CVPixelBufferLockBaseAddress(depthFrame, .readOnly)
                let rowData = CVPixelBufferGetBaseAddress(depthFrame)! + Int(depthPoint.y) * CVPixelBufferGetBytesPerRow(depthFrame)
                // swift does not have an Float16 data type. Use UInt16 instead, and then translate
                var f16Pixel = rowData.assumingMemoryBound(to: UInt16.self)[Int(depthPoint.x)]
                var f32Pixel = Float(0.0)

                CVPixelBufferUnlockBaseAddress(depthFrame, .readOnly)
                
                withUnsafeMutablePointer(to: &f16Pixel) { f16RawPointer in
                    withUnsafeMutablePointer(to: &f32Pixel) { f32RawPointer in
                        var src = vImage_Buffer(data: f16RawPointer, height: 1, width: 1, rowBytes: 2)
                        var dst = vImage_Buffer(data: f32RawPointer, height: 1, width: 1, rowBytes: 4)
                        vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                    }
                }
                    
        //      END OF MAGIC FUNCTION.
                
                
                let measurement = f32Pixel * 100
                depthMeasurementsCumul += measurement
                if measurement > depthMeasurementMax {
                    depthMeasurementMax = measurement
                }
                if measurement < depthMeasurementMin {
                    depthMeasurementMin = measurement
                }
                
                depthMeasurementsLeftInLoop -= 1
                
                let printStr = String(format: "Measurement %d: %.2f cm",
                    depthMeasurementRepeats - depthMeasurementsLeftInLoop, measurement)
                print(printStr)
                
                depthMeasurementsString += String(format: "%.2f,", measurement)
            }
            
            if depthMeasurementsLeftInLoop == 0 {
                depthMeasurementsCumul = depthMeasurementsCumul / Float(depthMeasurementRepeats)
                
                // Convert the depth frame format to cm
                let depthString = String(format: "Depth: %.2f cm\nRange across %d readings: %.2f cm - %.2f cm", depthMeasurementsCumul, depthMeasurementRepeats, depthMeasurementMin, depthMeasurementMax)

                print(depthString)
                print(depthMeasurementsString)
                
                DispatchQueue.main.async {
                    self.depthLabel.text = depthString
                    self.depthLabel.isHidden = false
                    self.activityIndicator.isHidden = true
                }
                
                waitingToShowDepth = false
            }
        }
    }
    
    
    // MARK: Button Click Handler
    
    @IBAction func pressedCaptureButton(_ sender: Any) {
        waitingToShowDepth = true
    }
    
    
    // MARK: Thermal State Monitoring
    // The code in this marked section is subject to the licence 'AppleLICENCE.txt'. Modifications have been made.
    
    @objc
    func thermalStateChanged(notification: NSNotification) {
        
        if let processInfo = notification.object as? ProcessInfo {
            showThermalState(state: processInfo.thermalState)
        }
    }
    
    func showThermalState(state: ProcessInfo.ThermalState) {
        
        DispatchQueue.main.async {
            var thermalStateString = "unknown"
            if state == .nominal {
                thermalStateString = "normal"
            } else if state == .fair {
                thermalStateString = "fair"
            } else if state == .serious {
                thermalStateString = "serious"
            } else if state == .critical {
                thermalStateString = "critical"
            }
            
            let message = NSLocalizedString("Thermal state is \(thermalStateString).", comment: "Alert message when thermal state has changed")
            self.showAlert(title: "Thermal State Monitoring", msg: message)
        }
    }
    
    
    // MARK: Alert Function
    
    func showAlert(title: String, msg: String) {
        
        let alertController = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        let alertOkAction = UIAlertAction(title: "OK", style: .default, handler: nil)
        alertController.addAction(alertOkAction)
        present(alertController, animated: true, completion: nil)
    }

}
