import Foundation
import AVFoundation

/// Manages the daily audio bulletin (Bülten).
/// Downloads the pre-generated MP3 from GitHub Pages (generated once at 09:00 and 17:00 Istanbul
/// time for ALL users). Falls back to a "not ready yet" state if the file hasn't been generated.
///
/// SETUP: Replace `audioBaseURL` with your actual GitHub Pages URL after pushing the repo.
final class BültenManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = BültenManager()

    // -----------------------------------------------------------------------
    // MARK: - Configuration  ← CHANGE THIS after creating your GitHub repo
    // Format: https://YOUR_USERNAME.github.io/YOUR_REPO_NAME
    // -----------------------------------------------------------------------
    private let audioBaseURL = "https://ermalhamzaj1.github.io/audiohaberz"

    // MARK: - Published State
    @Published var headlines: [NewsItem] = []
    @Published var isPlaying = false
    @Published var isGenerating = false   // reused as "isDownloading" in UI
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var lastGenerated: Date?
    @Published var slotLabel: String = "Sabah"
    @Published var hasAudio = false
    @Published var generationError: String?

    // MARK: - Private
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private let rssURL = "https://www.sabah.com.tr/rss/gundem.xml"

    private override init() {
        super.init()
        bustCacheIfNeeded()
        loadCachedHeadlines()
    }

    private func bustCacheIfNeeded() {
        let versionKey = "bultenScriptVersion"
        let currentVersion = 3 // bumped: switched from local TTS to server download
        if UserDefaults.standard.integer(forKey: versionKey) < currentVersion {
            let dir = cacheDir
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                files.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            UserDefaults.standard.set(currentVersion, forKey: versionKey)
        }
    }

    // MARK: - Slot

    enum Slot {
        case morning, evening

        var label: String { self == .morning ? "Sabah" : "Akşam" }
        var hour: Int    { self == .morning ? 9 : 17 }
        var serverFilename: String { self == .morning ? "bulten_morning.mp3" : "bulten_evening.mp3" }

        func cacheKey(date: Date) -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "Europe/Istanbul")!
            return "bulten_\(hour)h_\(f.string(from: date))"
        }

        func audioFileURL(in dir: URL, date: Date) -> URL {
            dir.appendingPathComponent("\(cacheKey(date: date)).mp3")
        }
    }

    private var turkishCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return cal
    }

    private var activeSlot: Slot? {
        let hour = turkishCalendar.component(.hour, from: Date())
        if hour >= 17 { return .evening }
        if hour >= 9  { return .morning }
        return nil
    }

    private lazy var cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BultenAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Check & Download

    func checkAndGenerateIfNeeded() {
        guard let slot = activeSlot else {
            slotLabel = "Sabah"
            return
        }
        slotLabel = slot.label
        let localURL = slot.audioFileURL(in: cacheDir, date: Date())
        if FileManager.default.fileExists(atPath: localURL.path) {
            hasAudio = true
            return
        }
        Task { await download(slot: slot) }
    }

    func regenerate() {
        guard let slot = activeSlot else { return }
        try? FileManager.default.removeItem(at: slot.audioFileURL(in: cacheDir, date: Date()))
        hasAudio = false
        progress = 0
        stop()
        Task { await download(slot: slot) }
    }

    private func download(slot: Slot) async {
        await MainActor.run {
            isGenerating = true
            generationError = nil
        }
        do {
            let serverURL = "\(audioBaseURL)/\(slot.serverFilename)"
            guard let url = URL(string: serverURL) else { throw BültenError.invalidURL }

            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw BültenError.notReady
            }

            let dest = slot.audioFileURL(in: cacheDir, date: Date())
            try data.write(to: dest, options: .atomic)

            let all = await RSSParser().fetchNews(from: rssURL, sourceName: "Sabah")
            let top10 = Array(all.prefix(10))

            await MainActor.run {
                headlines = top10
                lastGenerated = Date()
                hasAudio = true
                isGenerating = false
                if !top10.isEmpty { saveHeadlines(top10) }
            }
        } catch BültenError.notReady {
            await MainActor.run {
                isGenerating = false
                generationError = "Bülten henüz hazır değil. Saat 09:00 ve 17:00'de güncellenir."
            }
        } catch {
            await MainActor.run {
                isGenerating = false
                generationError = "Bülten yüklenemedi. Lütfen tekrar deneyin."
            }
        }
    }

    // MARK: - Playback

    func toggle() {
        if isPlaying {
            pause()
        } else if let player = audioPlayer, player.currentTime > 0 {
            resume()
        } else {
            play()
        }
    }

    func play() {
        guard let slot = activeSlot else { return }
        let url = slot.audioFileURL(in: cacheDir, date: Date())
        guard FileManager.default.fileExists(atPath: url.path) else {
            Task { await download(slot: slot) }
            return
        }
        configureAudioSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            duration = player.duration
            isPlaying = true
            startProgressTimer()
        } catch {}
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func resume() {
        audioPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        progress = 0
        stopProgressTimer()
    }

    func seek(to fraction: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = player.duration * fraction
        progress = fraction
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.progress = 0
            self.stopProgressTimer()
        }
    }

    // MARK: - Helpers

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer else { return }
            self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - Persistence

    private func saveHeadlines(_ items: [NewsItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "bultenHeadlinesV2")
        }
        UserDefaults.standard.set(lastGenerated, forKey: "bultenLastGenerated")
    }

    private func loadCachedHeadlines() {
        if let data = UserDefaults.standard.data(forKey: "bultenHeadlinesV2"),
           let items = try? JSONDecoder().decode([NewsItem].self, from: data) {
            headlines = items
        }
        lastGenerated = UserDefaults.standard.object(forKey: "bultenLastGenerated") as? Date
    }

    enum BültenError: Error {
        case invalidURL, notReady, networkError
    }
}

// MARK: - Legacy alias
typealias DailySummaryManager = BültenManager
