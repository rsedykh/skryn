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

/// Recording frame rate
enum FrameRate: Int, CaseIterable {
    case fps30 = 30, fps60 = 60

    var title: String { "\(rawValue) fps" }
}

/// Output settings for saved/uploaded files. Settings edits them; the encoders read them.
struct OutputSettings: StoredSettings {
    var imageFormat: ImageFormat = .png
    /// For AVIF / HEIC / WebP: lossless instead of `imageQuality`
    var imageLossless = true
    /// 0.1...1 for lossy images (JPEG, and AVIF/HEIC/WebP when not lossless)
    var imageQuality = 0.85
    var videoFormat: VideoFormat = .mp4H264
    /// Full Retina resolution; false saves at 1x (half the pixels each way on Retina displays)
    var retina = true
    var frameRate = FrameRate.fps30
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

    static let didChange = Notification.Name("OutputSettingsDidChange")

    static var fields: [StoredField<Self>] {
        [
            .raw("outputImageFormat", \.imageFormat),
            .value("outputImageLossless", \.imageLossless),
            .value("outputImageQuality", \.imageQuality),
            .raw("outputVideoFormat", \.videoFormat),
            .value("outputRetina", \.retina),
            .raw("outputFrameRate", \.frameRate),
            .value("outputStripMetadata", \.stripMetadata),
        ]
    }

    var normalized: OutputSettings {
        var copy = self
        copy.imageQuality = min(max(imageQuality, 0.1), 1)
        return copy
    }
}
