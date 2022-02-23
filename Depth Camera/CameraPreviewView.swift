//
//  CameraPreviewView.swift
//  Depth Camera
//
//  Created by James Bungay on 25/10/2021.
//  Copyright © 2021 James Bungay. All rights reserved.
//

import UIKit
import AVFoundation

class CameraPreviewView: UIView {
        
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    
    /// Convenience wrapper to get layer as its statically known type.
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
    
}
