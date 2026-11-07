@preconcurrency import AVFoundation
import SwiftUI
import Vision

/// Adds paper books by their barcode: point the Mac's camera — or an
/// iPhone's, through Continuity Camera — at the ISBN on the back cover.
@MainActor
final class BarcodeCamera: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published var deviceID = "" {
        didSet { if oldValue != deviceID { switchDevice() } }
    }
    @Published private(set) var allowed = true
    /// Where the barcode is in the picture (0–1, top-left origin), while one is seen.
    @Published private(set) var highlight: CGRect?
    /// Each ISBN read, once per sighting.
    var onISBN: ((String) -> Void)?

    private let reader = FrameReader()
    private let queue = DispatchQueue(label: "barcode-camera")
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        reader.onResult = { [weak self] isbn, box in
            Task { @MainActor in self?.seen(isbn, box) }
        }
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard allowed else { return }
        refreshDevices()
        // An iPhone can show up (or go away) while this is open.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func refreshDevices() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14, *) {
            types += [.continuityCamera, .external]
        } else {
            types.append(.externalUnknown)
        }
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        // An iPhone reads barcodes far better than the Mac's own camera.
        if !devices.contains(where: { $0.uniqueID == deviceID }) || isBuiltIn(deviceID), let phone = devices.first(where: { !isBuiltIn($0.uniqueID) }) {
            deviceID = phone.uniqueID
        } else if !devices.contains(where: { $0.uniqueID == deviceID }) {
            deviceID = devices.first?.uniqueID ?? ""
        }
    }

    private func isBuiltIn(_ id: String) -> Bool {
        devices.first { $0.uniqueID == id }?.deviceType == .builtInWideAngleCamera
    }

    private func switchDevice() {
        guard let chosen = devices.first(where: { $0.uniqueID == deviceID }) else { return }
        nonisolated(unsafe) let device = chosen
        let session = session, reader = reader
        queue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            session.inputs.forEach(session.removeInput)
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.outputs.isEmpty {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(reader, queue: reader.queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    private var lastISBN: String?
    private var lastSeen = Date.distantPast

    private func seen(_ isbn: String?, _ box: CGRect?) {
        highlight = box
        guard let isbn else {
            // Once the book's been out of view a moment, the same one can be read again.
            if Date().timeIntervalSince(lastSeen) > 2 { lastISBN = nil }
            return
        }
        lastSeen = Date()
        guard isbn != lastISBN else { return }
        lastISBN = isbn
        onISBN?(isbn)
    }

    /// Only book barcodes: EAN-13 starting 978 or 979, with a valid check digit.
    nonisolated static func isbn(fromBarcode payload: String?) -> String? {
        guard let payload, payload.count == 13, payload.allSatisfy(\.isNumber),
              payload.hasPrefix("978") || payload.hasPrefix("979"), ShareIntake.isValid(payload) else { return nil }
        return payload
    }
}

/// Looks for a barcode in camera frames, off the main thread.
private final class FrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "barcode-frames")
    var onResult: ((String?, CGRect?) -> Void)?
    private var last = Date.distantPast

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(last) > 0.12, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = Date()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13]
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        let hit = (request.results ?? []).first { BarcodeCamera.isbn(fromBarcode: $0.payloadStringValue) != nil }
        // Vision's box has its origin at the bottom left.
        let box = hit.map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                                   width: $0.boundingBox.width, height: $0.boundingBox.height) }
        onResult?(BarcodeCamera.isbn(fromBarcode: hit?.payloadStringValue), box)
    }
}

/// The camera picture, filling its frame, not mirrored (so the barcode reads the right way).
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) { }

    final class PreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            preview.videoGravity = .resizeAspectFill
            layer = preview          // layer-hosting: set the layer, then ask for one
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            if let connection = preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }
}

struct BarcodeScanSheet: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = BarcodeCamera()

    struct Scanned: Identifiable, Equatable {
        let isbn: String
        var book: Book?
        var looking = true
        /// The shelf it's on — already, or just added to.
        var shelf: String?
        var id: String { isbn }
    }

    @State private var scanned: [Scanned] = []
    @State private var typed = ""
    @State private var flash = false

    var body: some View {
        VStack(spacing: 0) {
            GlassHeader {
                Text("Scan a Barcode").appFont(size: 13, weight: .semibold)
                Spacer()
                if camera.devices.count > 1 {
                    Picker("Camera", selection: $camera.deviceID) {
                        ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).glassButton()
            }

            viewfinder
                .frame(height: 300)

            VStack(alignment: .leading, spacing: 12) {
                if let latest = scanned.first {
                    latestCard(latest)
                } else {
                    Text(camera.allowed ? String(localized: "Hold the barcode on the back cover in the frame, about a hand’s width from the camera.")
                                        : String(localized: "The app isn’t allowed to use the camera. Allow it in System Settings → Privacy & Security → Camera."))
                        .appFont(size: 12).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                }

                if scanned.count > 1 {
                    Divider()
                    HStack {
                        Text("Scanned before").appFont(size: 11, weight: .semibold).foregroundStyle(.secondary)
                        Spacer()
                        let pending = scanned.dropFirst().filter { $0.book != nil && $0.shelf == nil }
                        if !pending.isEmpty {
                            Button("Add \(pending.count) to Want to Read") {
                                Task { for item in pending { await shelve(item, to: .wantToRead) } }
                            }
                            .controlSize(.small)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(scanned.dropFirst()) { item in smallRow(item) }
                        }
                    }
                    .frame(maxHeight: 130)
                }

                HStack {
                    TextField("No camera handy? Type the ISBN", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTyped)
                    Button("Look Up", action: addTyped).disabled(ISBN.normalized(typed) == nil)
                }
            }
            .padding(14)
        }
        .frame(width: 560)
        .task {
            camera.onISBN = { isbn in found(isbn) }
            await camera.start()
        }
        .onDisappear { camera.stop() }
    }

    // MARK: Pieces

    private var viewfinder: some View {
        ZStack {
            Color.black
            if !camera.allowed || camera.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera").appFont(size: 30).foregroundStyle(.secondary)
                    Text(camera.allowed ? String(localized: "No camera found. With an iPhone nearby on the same Apple Account, Continuity Camera shows up here.")
                                        : String(localized: "No access to the camera."))
                        .appFont(size: 12).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            } else {
                CameraPreview(session: camera.session)
                GeometryReader { proxy in
                    // The guide; once a barcode is seen, a box around it instead.
                    if let box = camera.highlight {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.green, lineWidth: 3)
                            .frame(width: box.width * proxy.size.width + 16, height: box.height * proxy.size.height + 16)
                            .position(x: box.midX * proxy.size.width, y: box.midY * proxy.size.height)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .frame(width: proxy.size.width * 0.55, height: proxy.size.height * 0.4)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                }
                Color.white.opacity(flash ? 0.35 : 0).allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private func latestCard(_ item: Scanned) -> some View {
        HStack(alignment: .top, spacing: 12) {
            cover(item.book?.coverURL).frame(width: 56, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                if item.looking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking up \(item.isbn)…").appFont(size: 13)
                    }
                } else if let book = item.book {
                    Text(book.title).appFont(size: 14, weight: .semibold).lineLimit(2)
                    Text(book.author).appFont(size: 12).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    if let shelf = item.shelf {
                        Label(String(localized: "On \(shelf)"), systemImage: "checkmark.circle.fill")
                            .appFont(size: 12).foregroundStyle(.green)
                    } else {
                        HStack(spacing: 6) {
                            ForEach(Shelf.builtIn) { shelf in
                                Button(shelf.title) { Task { await shelve(item, to: shelf) } }
                                    .controlSize(.small)
                                    .keyboardShortcut(shelf == .wantToRead ? .defaultAction : nil)
                            }
                            if model.shelves.count > 3 {
                                Menu("Other") {
                                    ForEach(model.shelves.filter { !$0.isBuiltIn }) { shelf in
                                        Button(shelf.title) { Task { await shelve(item, to: shelf) } }
                                    }
                                }
                                .controlSize(.small)
                                .fixedSize()
                            }
                        }
                    }
                } else {
                    Text("No book found for ISBN \(item.isbn).").appFont(size: 13)
                    Text("Try typing the title in Search.").appFont(size: 11).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(minHeight: 84)
        .contentShape(Rectangle())
        .onTapGesture { if let book = item.book { model.showBookDetail(book) } }
    }

    private func smallRow(_ item: Scanned) -> some View {
        HStack(spacing: 8) {
            cover(item.book?.coverURL).frame(width: 20, height: 30)
            Text(item.book?.title ?? item.isbn).appFont(size: 12).lineLimit(1)
            Spacer()
            if let shelf = item.shelf {
                Text(shelf).appFont(size: 11).foregroundStyle(.green)
            } else if item.book != nil {
                Menu("Add") {
                    ForEach(model.shelves) { shelf in
                        Button(shelf.title) { Task { await shelve(item, to: shelf) } }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private func cover(_ url: URL?) -> some View {
        CachedAsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: Actions

    private func addTyped() {
        guard let isbn = ISBN.normalized(typed) else { return }
        typed = ""
        found(isbn)
    }

    private func found(_ isbn: String) {
        // Seen again: bring it back to the top rather than listing it twice.
        if let index = scanned.firstIndex(where: { $0.isbn == isbn }) {
            scanned.insert(scanned.remove(at: index), at: 0)
            return
        }
        NSSound(named: "Tink")?.play()
        withAnimation(.easeOut(duration: 0.25)) { flash = true }
        withAnimation(.easeIn(duration: 0.3).delay(0.15)) { flash = false }
        scanned.insert(Scanned(isbn: isbn), at: 0)
        Task {
            let result = await Self.lookUp(isbn)
            guard let index = scanned.firstIndex(where: { $0.isbn == isbn }) else { return }
            scanned[index].book = result
            scanned[index].looking = false
            scanned[index].shelf = result.flatMap { shelfName(of: $0) }
        }
    }

    /// The Goodreads edition with this ISBN and its details — from its
    /// Goodreads page, else Google Books.
    private static func lookUp(_ isbn: String) async -> Book? {
        async let google = try? GoogleBooksClient.search(isbn).first
        guard let bookID = await GoodreadsLookup.bookID(isbn: isbn) else { return await google }
        var book = await google ?? Book(id: isbn, title: "", author: "", coverURL: nil, rating: nil, isbn: isbn)
        if book.title.isEmpty || book.coverURL == nil,
           let about = (try? await GoodreadsBookPage.fetch(bookID: bookID))?.about {
            book = Book(id: book.id, title: book.title.isEmpty ? (about.title ?? isbn) : book.title,
                        author: book.author.isEmpty ? (about.authorName ?? "") : book.author,
                        coverURL: book.coverURL ?? about.coverURL, rating: book.rating,
                        publisher: book.publisher ?? about.publisher, isbn: isbn)
        }
        book.goodreadsID = bookID
        if book.isbn == nil { book.isbn = isbn }
        return book
    }

    /// Which of your shelves the book is on already, by Goodreads id or ISBN.
    private func shelfName(of book: Book) -> String? {
        for shelf in model.shelves {
            let entries = ShelfCache.read(shelf)?.entries ?? []
            if entries.contains(where: { $0.bookID == book.goodreadsID || ($0.isbn13 ?? $0.isbn) == book.isbn }) {
                return shelf.title
            }
        }
        return nil
    }

    private func shelve(_ item: Scanned, to shelf: Shelf) async {
        guard let book = item.book else { return }
        await model.shelve(book, to: shelf)
        if let index = scanned.firstIndex(where: { $0.isbn == item.isbn }), model.status?.isError != true {
            scanned[index].shelf = shelf.title
        }
    }
}
