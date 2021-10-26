//
//  ViewController.swift
//  TremorCamera
//
//  Created by James Bungay on 25/10/2021.
//  Copyright © 2021 James Bungay. All rights reserved.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    private let captureSession = AVCaptureSession()

    @IBOutlet weak var cameraPreviewView: CameraPreviewView!
    
    
    // MARK: ViewController Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        // Verify authorisation for video capture, and then set up captureSession:
        
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized || AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            self.setUpCaptureSession()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        
        let initialThermalState = ProcessInfo.processInfo.thermalState
        showThermalState(state: initialThermalState)
        
        // If unauthorised for video capture, display an alert explaining why:
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied: // The user has previously denied access.
                showAlert(title: "No camera access", msg: "Please allow camera access in settings for CarbonCamera to use this app.")
                return
            case .restricted: // The user can't grant access due to restrictions.
                showAlert(title: "No camera access", msg: "Your parental restrictions prevent you from using the camera. Camera access is needed to use this app.")
                return
            default:
                return
        }
    }
    
    
    // MARK: captureSession Setup
    
    func setUpCaptureSession() {
        
        captureSession.beginConfiguration()  // Must be called before beginning capture session configuration
        
        // Setup camera input to captureSession:
        
        guard let videoDevice = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            else { return }  // Configuration failed, no true depth camera.
        
        guard let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice)
            else { return }  // Configuration failed, cannot use camera as capture input device.
        
        do {
            try videoDeviceInput.device.lockForConfiguration()
        } catch { return }
        
        // Select an absolute depth (not disparity) format that works with the active color format:
        // There are two available formats for absolute depth: hdep and fdep (16 or 32 bit float values)
        let availableFormats = videoDevice.activeFormat.supportedDepthDataFormats
        let depthFormat = availableFormats.filter { format in
            let pixelFormatType =
                CMFormatDescriptionGetMediaSubType(format.formatDescription)
            
            return (pixelFormatType == kCVPixelFormatType_DepthFloat16 ||
                    pixelFormatType == kCVPixelFormatType_DepthFloat32)
        }.first
        videoDevice.activeDepthDataFormat = depthFormat
        
        videoDeviceInput.device.unlockForConfiguration()
        
        if captureSession.canAddInput(videoDeviceInput) {
            captureSession.addInput(videoDeviceInput)
        } else { return }  // Configuration failed, cannot add input to captureSession.
        
        
        // Set up photo output for depth data capture:
        
        let photoOutput = AVCapturePhotoOutput()
        
        // Enable depth data capture if depth data capture is supported by the camera:
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        
        guard self.captureSession.canAddOutput(photoOutput)
            else { fatalError("Can't add photo output.") }
        self.captureSession.addOutput(photoOutput)
        
        self.captureSession.sessionPreset = .photo
        
        
        // Setup preview for captureSession:
        
        cameraPreviewView.videoPreviewLayer.session = captureSession
        cameraPreviewView.videoPreviewLayer.videoGravity = .resizeAspect  // Set video preview to fit the view with no overflow
        
        
        captureSession.commitConfiguration()  // Must be called after completing capture session configuration, before committing
        
        let serialQueue = DispatchQueue(label: "queue.serial.startCaptureSession")
        serialQueue.async {
            self.captureSession.startRunning()
        }
    }

    
    // MARK: Thermal State Monitoring
    // The code in this marked section is subject to the licence 'AppleLICENCE.txt'. Modifications have been made.
    
    // You can use this opportunity to take corrective action to help cool the system down.
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

