//
//  ViewController.swift
//  Depth Camera
//
//  Created by James Bungay on 25/10/2021.
//  Copyright © 2021 James Bungay. All rights reserved.
//

import UIKit
import AVFoundation
import Accelerate

class ViewController: UIViewController, AVCaptureDepthDataOutputDelegate {
    
    private let captureSession = AVCaptureSession()
    
    private let depthDataOutput = AVCaptureDepthDataOutput()
    
    // Communicate with the session and other session objects on this queue:
    private let sessionQueue = DispatchQueue(label: "capture session queue")
    
    // Depth data handled on this synchronous queue:
    private let dataOutputQueue = DispatchQueue(label: "depth data queue", qos: .userInitiated)
    
    
    @IBOutlet weak var cameraPreviewView: CameraPreviewView!
    
    @IBOutlet weak var captureButton: UIButton!
    
    @IBOutlet weak var depthLabel: UILabel!
    
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    
    // Indicates whether the button 'capture depth measurement' button has been pressed:
    private var waitingToShowDepth = false
    
    // Used for calculating the average of multiple (default 10) depth measurements:
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
                showAlert(title: "No camera access", msg: "Please allow camera access in settings to use this app.")
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
        
        // Setup camera input to captureSession:
        guard let videoDevice = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            else {
                // Configuration failed, device has no true depth camera.
                print("Device has no TrueDepth camera.")
                return
            }

        guard let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice)
            else {
                // Configuration failed, cannot use camera as capture input device.
                print("Could not use camera as input device for capture session.")
                return
            }

        captureSession.beginConfiguration()
        
        captureSession.sessionPreset = AVCaptureSession.Preset.vga640x480
        
        // Add video input:
        if captureSession.canAddInput(videoDeviceInput) {
            captureSession.addInput(videoDeviceInput)
        } else {
            // Configuration failed, cannot add input to captureSession.
            print("Could not use camera as input device for capture session.")
            return
        }
        
        // Add depth data output:
        if captureSession.canAddOutput(depthDataOutput) {
            captureSession.addOutput(depthDataOutput)
            // Don't apply noise filtering to depth data:
            depthDataOutput.isFilteringEnabled = false
        } else {
            // Configuration failed, cannot add depth data output to captureSession.
            print("Could not add depth data output to the capture session.")
            return
        }
        depthDataOutput.setDelegate(self, callbackQueue: dataOutputQueue)
        
        // Search for highest resolution depth format with half-point depth values:
        let availableFormats = videoDevice.activeFormat.supportedDepthDataFormats
        let selectedFormat = availableFormats.filter { f in
            CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_DepthFloat16
        }.max(by: {
            first, second in CMVideoFormatDescriptionGetDimensions(first.formatDescription).width < CMVideoFormatDescriptionGetDimensions(second.formatDescription).width
        })
                
        // Set depth data format to the one which was chosen above:
        do {
            try videoDevice.lockForConfiguration()
        } catch {
            print("Could not lock camera for configuration.")
            return
        }
        videoDevice.activeDepthDataFormat = selectedFormat
        videoDevice.unlockForConfiguration()

        // Must be called after completing capture session configuration:
        captureSession.commitConfiguration()

        // Set up preview for captureSession:
        DispatchQueue.main.async {
            self.cameraPreviewView.videoPreviewLayer.session = self.captureSession
            // Set video preview to fit the view with no overflow:
            self.cameraPreviewView.videoPreviewLayer.videoGravity = .resizeAspect
        }

        sessionQueue.async {
            self.captureSession.startRunning()
        }
    }

    
    // MARK: Depth Data Delegate
    
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

                // Measure depth at the centre of the camera frame:
                let depthPoint = CGPoint(x: CGFloat(CVPixelBufferGetWidth(depthFrame)) / 2, y: CGFloat(CVPixelBufferGetHeight(depthFrame) / 2))
                
                
                // Get the depth value from the point defined by 'depthPoint' from the frame of depth data 'depthFrame':
                /// The code following this line is subject to the licence 'AppleLICENCE.txt':
                assert(kCVPixelFormatType_DepthFloat16 == CVPixelBufferGetPixelFormatType(depthFrame))
                CVPixelBufferLockBaseAddress(depthFrame, .readOnly)
                let rowData = CVPixelBufferGetBaseAddress(depthFrame)! + Int(depthPoint.y) * CVPixelBufferGetBytesPerRow(depthFrame)
                // Swift does not have a Float16 data type. Use UInt16 instead, and then translate:
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
                /// End of code which is subject to AppleLICENCE.
                
                // Convert from depth frame format to cm:
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
    
    /// The code following this line is subject to the licence 'AppleLICENCE.txt'. Modifications have been made.
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
    /// End of code which is subject to AppleLICENCE.
    
    
    // MARK: Alert Function
    
    func showAlert(title: String, msg: String) {
        
        let alertController = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        let alertOkAction = UIAlertAction(title: "OK", style: .default, handler: nil)
        alertController.addAction(alertOkAction)
        present(alertController, animated: true, completion: nil)
    }

}
