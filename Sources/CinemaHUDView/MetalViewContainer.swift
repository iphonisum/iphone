//
//  MetalViewContainer.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  120Hz ProMotion MTKView Container:
//  Direct CAMetalLayer binding (presentsWithTransaction = false),
//  frame pacing at 120Hz, and zero CPU memory copy rendering.
//

import SwiftUI
import MetalKit
import CoreVideo
import AVFoundation

public struct MetalViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: CinemaCameraViewModel
    
    public init(viewModel: CinemaCameraViewModel) {
        self.viewModel = viewModel
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }
    
    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = viewModel.metalContext.device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 120 // ProMotion 120Hz display pacing
        
        // Zero-Lag Mandate: Direct layer presentation without transaction latency
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = false
        }
        
        mtkView.delegate = context.coordinator
        context.coordinator.setupEngineSubscription()
        return mtkView
    }
    
    public func updateUIView(_ uiView: MTKView, context: Context) {}
    
    public final class Coordinator: NSObject, MTKViewDelegate, CoreCaptureEngineDelegate {
        var viewModel: CinemaCameraViewModel
        private var latestSampleBuffer: CMSampleBuffer?
        private let lock = NSLock()
        
        init(viewModel: CinemaCameraViewModel) {
            self.viewModel = viewModel
            super.init()
        }
        
        func setupEngineSubscription() {
            viewModel.captureEngine.delegate = self
        }
        
        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        
        public func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }
            
            var bufferToRender: CMSampleBuffer?
            lock.lock()
            bufferToRender = latestSampleBuffer
            lock.unlock()
            
            if let sample = bufferToRender {
                viewModel.renderFrame(to: drawable, sampleBuffer: sample)
            }
        }
        
        // MARK: - CoreCaptureEngineDelegate
        public func captureEngine(_ engine: CoreCaptureEngine, didOutput sampleBuffer: CMSampleBuffer) {
            lock.lock()
            latestSampleBuffer = sampleBuffer
            lock.unlock()
        }
        
        public func captureEngine(_ engine: CoreCaptureEngine, didChangeLens device: AVCaptureDevice) {}
        public func captureEngine(_ engine: CoreCaptureEngine, didEncounterError error: Error) {}
    }
}
