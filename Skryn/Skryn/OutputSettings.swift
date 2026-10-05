import Foundation

/// File format for saved and uploaded screenshots. The clipboard always gets PNG + TIFF, which every app pastes.
enum ImageFormat: String, CaseIterable {
    case png, jpeg, avif, heic, webp, pdf

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .avif: "AVIF"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .pdf: "PDF"
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    /// Formats with a lossless mode besides PNG (always lossless) and PDF (embeds lossless).
    var hasLosslessOption: Bool { self == .avif || self == .heic || self == .webp }
    /// macOS writes AVIF/HEIC "lossless" a few levels off the original; only WebP's is exact
    var isLosslessExact: Bool { self == .webp }
    /// Formats where the quality setting applies (when not lossless).
    var hasQuality: Bool { self == .jpeg || hasLosslessOption }
}

/// File format for recordings. MP4/MOV come straight from the recorder; GIF and WebP are converted from it.
enum VideoFormat: String, CaseIterable {
    case mp4H264 = "mp4-h264", mp4HEVC = "mp4-hevc", mov, gif, webp

    var title: String {
        switch self {
        case .mp4H264: "MP4 (H.264)"
        case .mp4HEVC: "MP4 (HEVC)"
        case .mov: "MOV (H.264)"
        case .gif: "Animated GIF"
        case .webp: "Animated WebP"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC: "mp4"
        case .mov: "mov"
        case .gif: "gif"
        case .webp: "webp"
        }
    }

    /// Animated image formats: no audio, and frames are converted after recording.
    var isAnimatedImage: Bool { self == .gif || self == .webp }
}

/// Output settings for saved/uploaded files. Settings edits them; the encoders read them.
struct OutputSettings: Equatable {
    var imageFormat: ImageFormat = .png
    /// For AVIF / HEIC / WebP: lossless instead of `imageQuality`
    var imageLossless = true
    /// 0...1 for lossy images (JPEG, and AVIF/HEIC/WebP when not lossless)
    var imageQuality = 0.85
    var videoFormat: VideoFormat = .mp4H264
    /// Full Retina resolution; false saves at 1x (half the pixels each way on Retina displays)
    var retina = true
    /// Recording frame rate: 30 or 60
    var frameRate = 30
    /// Drop capture metadata (EXIF, color sync dates, software tags) from saved images
    var stripMetadata = true

    /// One-click presets. `.compatible` is the default: opens and pastes everywhere.
    enum Preset: String, CaseIterable {
        case compatible, compact

        var title: String { self == .compatible ? "Compatible" : "Compact" }
        var summary: String {
            self == .compatible ? "PNG and MP4 (H.264): open everywhere" : "Lossless WebP and MP4 (HEVC): smaller files"
        }

        func apply(to settings: inout OutputSettings) {
            settings.imageFormat = self == .compatible ? .png : .webp
            settings.imageLossless = true
            settings.videoFormat = self == .compatible ? .mp4H264 : .mp4HEVC
        }
    }

    /// The preset these settings match, or nil for a custom combination.
    var preset: Preset? {
        Preset.allCases.first { preset in
            var copy = self
            preset.apply(to: &copy)
            return copy == self
        }
    }

    /// Posted whenever `current` is written, so open UIs stay in sync.
    static let didChange = Notification.Name("OutputSettingsDidChange")

    private enum Key {
        static let imageFormat = "outputImageFormat"
        static let imageLossless = "outputImageLossless"
        static let imageQuality = "outputImageQuality"
        static let videoFormat = "outputVideoFormat"
        static let retina = "outputRetina"
        static let frameRate = "outputFrameRate"
        static let stripMetadata = "outputStripMetadata"
    }

    static var current: OutputSettings {
        get {
            let defaults = UserDefaults.standard
            let fallback = OutputSettings()
            return OutputSettings(
                imageFormat: defaults.string(forKey: Key.imageFormat).flatMap(ImageFormat.init) ?? fallback.imageFormat,
                imageLossless: defaults.object(forKey: Key.imageLossless) as? Bool ?? fallback.imageLossless,
                imageQuality: defaults.object(forKey: Key.imageQuality) as? Double ?? fallback.imageQuality,
                videoFormat: defaults.string(forKey: Key.videoFormat).flatMap(VideoFormat.init) ?? fallback.videoFormat,
                retina: defaults.object(forKey: Key.retina) as? Bool ?? fallback.retina,
                frameRate: [30, 60].contains(defaults.integer(forKey: Key.frameRate))
                    ? defaults.integer(forKey: Key.frameRate) : fallback.frameRate,
                stripMetadata: defaults.object(forKey: Key.stripMetadata) as? Bool ?? fallback.stripMetadata
            )
        }
        set {
            guard newValue != current else { return }
            let defaults = UserDefaults.standard
            defaults.set(newValue.imageFormat.rawValue, forKey: Key.imageFormat)
            defaults.set(newValue.imageLossless, forKey: Key.imageLossless)
            defaults.set(min(max(newValue.imageQuality, 0.1), 1), forKey: Key.imageQuality)
            defaults.set(newValue.videoFormat.rawValue, forKey: Key.videoFormat)
            defaults.set(newValue.retina, forKey: Key.retina)
            defaults.set(newValue.frameRate, forKey: Key.frameRate)
            defaults.set(newValue.stripMetadata, forKey: Key.stripMetadata)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
