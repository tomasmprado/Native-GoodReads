@preconcurrency import AVFoundation
import SwiftUI
import Vision

/// Adds paper books by their barcode: point the Mac's camera — or an
/// iPhone's, through Continuity Camera — at the ISBN on the back cover.
final class BarcodeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "barcode-camera")
    private var lastScan = Date.distantPast
    /// Called on the main thread with each ISBN seen.
    var onISBN: (@MainActor (String) -> Void)?

    static var devices: [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14, *) {
            types += [.continuityCamera, .external]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func use(_ device: AVCaptureDevice) {
        nonisolated(unsafe) let device = device
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.outputs.isEmpty {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // A few looks a second is plenty, and keeps the fan quiet.
        guard Date().timeIntervalSince(lastScan) > 0.25,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = Date()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13]
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        for result in request.results ?? [] {
            guard let isbn = BarcodeCamera.isbn(fromBarcode: result.payloadStringValue) else { continue }
            let callback = onISBN
            DispatchQueue.main.async { callback?(isbn) }
        }
    }

    /// Only book barcodes: EAN-13 starting 978 or 979, with a valid check digit.
    static func isbn(fromBarcode payload: String?) -> String? {
        guard let payload, payload.count == 13, payload.allSatisfy(\.isNumber),
              payload.hasPrefix("978") || payload.hasPrefix("979"), ShareIntake.isValid(payload) else { return nil }
        return payload
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}

struct BarcodeScanSheet: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    struct Scanned: Identifiable, Equatable {
        let isbn: String
        var book: Book?
        var looking = true
        var shelvedOn: String?
        var id: String { isbn }
    }

    @State private var camera = BarcodeCamera()
    @State private var devices: [AVCaptureDevice] = []
    @State private var deviceID = ""
    @State private var denied = false
    @State private var scanned: [Scanned] = []
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Scan a Barcode").appFont(size: 13, weight: .semibold)
                Spacer()
                if devices.count > 1 {
                    Picker("Camera", selection: $deviceID) {
                        ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).glassButton()
            }
            HStack(alignment: .top, spacing: 0) {
                ZStack {
                    if denied || devices.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "camera").appFont(size: 30).foregroundStyle(.tertiary)
                            Text(denied ? String(localized: "The app isn’t allowed to use the camera. Allow it in System Settings → Privacy & Security → Camera.")
                                        : String(localized: "No camera found. With an iPhone nearby on the same Apple Account, Continuity Camera shows up here."))
                                .appFont(size: 12).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .padding()
                    } else {
                        CameraPreview(session: camera.session)
                        RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 2)
                            .frame(width: 220, height: 110)
                    }
                }
                .frame(width: 340, height: 300)
                .background(Color.black.opacity(0.85))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Hold the barcode on the back cover up to the camera. Each book found is listed here.")
                        .appFont(size: 11).foregroundStyle(.secondary)
                    HStack {
                        TextField("Or type an ISBN", text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTyped)
                        Button("Add", action: addTyped).disabled(ISBN.normalized(typed) == nil)
                    }
                    List(scanned) { item in row(item) }
                        .listStyle(.inset)
                    HStack {
                        Spacer()
                        Button("Add All to Want to Read") {
                            Task {
                                for item in scanned where item.shelvedOn == nil { await shelve(item, to: .wantToRead) }
                            }
                        }
                        .disabled(!scanned.contains { $0.book != nil && $0.shelvedOn == nil })
                    }
                }
                .padding(12)
                .frame(width: 340, height: 300)
            }
        }
        .task {
            denied = !(await BarcodeCamera.requestAccess())
            devices = BarcodeCamera.devices
            // An iPhone's camera is the better one for reading barcodes.
            let preferred = devices.first { $0.deviceType != .builtInWideAngleCamera } ?? devices.first
            deviceID = preferred?.uniqueID ?? ""
            camera.onISBN = { isbn in found(isbn) }
            if !denied, let preferred { camera.use(preferred) }
        }
        .onChange(of: deviceID) { id in
            if !denied, let device = devices.first(where: { $0.uniqueID == id }) { camera.use(device) }
        }
        .onDisappear { camera.stop() }
    }

    private func row(_ item: Scanned) -> some View {
        HStack(spacing: 8) {
            CachedAsyncImage(url: item.book?.coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 28, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.book?.title ?? (item.looking ? String(localized: "Looking up \(item.isbn)…") : String(localized: "No book found for \(item.isbn)")))
                    .appFont(size: 12, weight: .medium).lineLimit(2)
                if let shelf = item.shelvedOn {
                    Label(shelf, systemImage: "checkmark").appFont(size: 10).foregroundStyle(.green)
                } else if let author = item.book?.author {
                    Text(author).appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if item.book != nil, item.shelvedOn == nil {
                Menu {
                    ForEach(model.shelves) { shelf in
                        Button(shelf.title) { Task { await shelve(item, to: shelf) } }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func addTyped() {
        guard let isbn = ISBN.normalized(typed) else { return }
        typed = ""
        found(isbn)
    }

    private func found(_ isbn: String) {
        guard !scanned.contains(where: { $0.isbn == isbn }) else { return }
        NSSound(named: "Tink")?.play()
        scanned.insert(Scanned(isbn: isbn), at: 0)
        Task {
            var book = (try? await GoogleBooksClient.search(isbn))?.first
            if var found = book, found.isbn == nil { found.isbn = isbn; book = found }
            if let bookID = await GoodreadsLookup.bookID(isbn: isbn) {
                book = book ?? Book(id: isbn, title: isbn, author: "", coverURL: nil, rating: nil, isbn: isbn)
                book?.goodreadsID = bookID
            }
            if let index = scanned.firstIndex(where: { $0.isbn == isbn }) {
                scanned[index].book = book
                scanned[index].looking = false
            }
        }
    }

    private func shelve(_ item: Scanned, to shelf: Shelf) async {
        guard let book = item.book else { return }
        await model.shelve(book, to: shelf)
        if let index = scanned.firstIndex(where: { $0.isbn == item.isbn }), model.status?.isError != true {
            scanned[index].shelvedOn = shelf.title
        }
    }
}
