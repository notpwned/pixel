//
//  FacePixelateCameraViewModel.swift
//  pixel
//
//  Created by adam on 01.01.2026.
//

import Foundation
import AVFoundation
import Vision
import CoreImage
import ImageIO

final class FacePixelateCameraViewModel: NSObject, ObservableObject {

    @Published var currentFrame: CGImage?
    @Published var statusText: String = "Запрос доступа к камере…"

    @Published private(set) var uiPixelScale: Double = 40
    @Published private(set) var uiFacePadding: Double = 0.22

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "camera.video.queue")
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")

    private let ciContext = CIContext()

    private let faceRequest = VNDetectFaceRectanglesRequest()

    private var lastFaceRects: [CGRect] = []
    private var lastFaceRectsFrame: Int = 0
    private var frameIndex: Int = 0
    private let graceFramesWithoutFaces = 10

    private struct Settings {
        var pixelScale: Float = 40
        var facePadding: Float = 0.22
    }

    private let settingsLock = NSLock()
    private var settings = Settings()

    private var isConfigured = false

    func commitPixelScale(_ v: Double) {
        let clamped = min(max(v, 20), 400)
        DispatchQueue.main.async { self.uiPixelScale = clamped }
        settingsLock.lock()
        settings.pixelScale = Float(clamped)
        settingsLock.unlock()
    }

    func commitFacePadding(_ v: Double) {
        let clamped = min(max(v, 0.0), 1.5)
        DispatchQueue.main.async { self.uiFacePadding = clamped }
        settingsLock.lock()
        settings.facePadding = Float(clamped)
        settingsLock.unlock()
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in self?.configureIfNeededAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.sessionQueue.async { self.configureIfNeededAndRun() }
                } else {
                    DispatchQueue.main.async { self.statusText = "Нет доступа к камере (разрешение отклонено)." }
                }
            }
        case .denied, .restricted:
            statusText = "Нет доступа к камере. Разреши в System Settings → Privacy → Camera."
        @unknown default:
            statusText = "Неизвестный статус разрешения камеры."
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeededAndRun() {
        guard !isConfigured else {
            if !session.isRunning { session.startRunning() }
            return
        }

        DispatchQueue.main.async { self.statusText = "Запуск камеры…" }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.statusText = "Камера не найдена." }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.statusText = "Нельзя добавить input камеры." }
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { self.statusText = "Не удалось создать input: \(error.localizedDescription)" }
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.statusText = "Нельзя добавить video output." }
            return
        }
        session.addOutput(videoOutput)

        session.commitConfiguration()

        isConfigured = true
        session.startRunning()

        DispatchQueue.main.async { self.statusText = "Камера запущена." }
    }
}

extension FacePixelateCameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameIndex += 1

        settingsLock.lock()
        let s = settings
        settingsLock.unlock()

        let orientation: CGImagePropertyOrientation = .up

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([faceRequest])

        let faces = (faceRequest.results as? [VNFaceObservation]) ?? []

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        var faceRects: [CGRect] = []
        faceRects.reserveCapacity(faces.count)

        for f in faces {
            let r = VNImageRectForNormalizedRect(f.boundingBox, w, h)
            let padX = CGFloat(s.facePadding) * r.width
            let padY = CGFloat(s.facePadding) * r.height * 1.15
            faceRects.append(r.insetBy(dx: -padX, dy: -padY))
        }

        if !faceRects.isEmpty {
            lastFaceRects = faceRects
            lastFaceRectsFrame = frameIndex
        } else if (frameIndex - lastFaceRectsFrame) <= graceFramesWithoutFaces {
            faceRects = lastFaceRects
        } else {
            lastFaceRects.removeAll(keepingCapacity: true)
        }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = inputImage.extent

        let pixellated = inputImage
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: s.pixelScale])
            .cropped(to: extent)

        var mask = CIImage(color: .black).cropped(to: extent)
        for rect in faceRects {
            let clipped = rect.intersection(extent)
            guard !clipped.isNull, clipped.width > 2, clipped.height > 2 else { continue }

            let white = CIImage(color: .white).cropped(to: clipped)
            mask = white.applyingFilter("CISourceOverCompositing",
                                        parameters: [kCIInputBackgroundImageKey: mask])
        }

        let softMask = mask
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
            .cropped(to: extent)

        let composited = pixellated.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: inputImage,
                kCIInputMaskImageKey: softMask
            ]
        )

        let mirrored = composited
            .transformed(by: CGAffineTransform(translationX: extent.width, y: 0).scaledBy(x: -1, y: 1))
            .cropped(to: extent)

        guard let cg = ciContext.createCGImage(mirrored, from: extent) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.currentFrame = cg
        }
    }
}
