import FlareAppleUI
import FlareAppleCore
import Foundation
import GSPlayer
import Kingfisher
import KotlinSharedUI
import Photos
import UIKit
import SwiftUI
import Drops

/// 批量保存图片时的一张待保存项。
nonisolated struct MediaImageSaveItem: Sendable {
    /// 原图地址。
    let url: String
    /// 原图拿不到时（403 / 防盗链 / 链接失效）退回这张，通常是预览图。
    let fallbackUrl: String?
    let customHeaders: [String: String]?

    init(url: String, fallbackUrl: String? = nil, customHeaders: [String: String]? = nil) {
        self.url = url
        self.fallbackUrl = fallbackUrl
        self.customHeaders = customHeaders
    }
}

class MediaSaver: NSObject, UIDocumentPickerDelegate {
    private override init() {}
    
    static let shared = MediaSaver()
    private var pendingFileExports: [ObjectIdentifier: PendingFileExport] = [:]

    nonisolated static func showPreparingMedia() {
        showPreparingMediaNotification()
    }

    func showDownloadStarted() {
        showDownloadStarted(mediaType: .file)
    }

    func showBatchSaveResult(success: Bool) {
        showSaveResult(success: success, mediaType: .photoAlbum)
    }

    func saveUgoira(_ media: UiMediaUgoira, fileName: String, showsSaveResult: Bool = true, completion: (@Sendable (Bool) -> Void)? = nil) {
        UgoiraExporter.shared.save(media, fileName: fileName, write: { url in
            let success: Bool = await withCheckedContinuation { continuation in
                self.saveVideoFileToPhotos(url, showsSaveResult: showsSaveResult) { continuation.resume(returning: $0) }
            }
            if !success { throw CocoaError(.fileWriteUnknown) }
        }, completion: { success in completion?(success) })
    }

    func saveImage(
        url: String,
        customHeaders: [String: String]? = nil,
        showsDownloadStarted: Bool = true,
        showsSaveResult: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard let remoteUrl = URL(string: url) else {
            finishSave(success: false, mediaType: .image, showsSaveResult: showsSaveResult, completion: completion)
            return
        }
        if showsDownloadStarted {
            showDownloadStarted(mediaType: .image)
        }
        saveRemoteOriginalDataToPhotos(
            from: remoteUrl,
            customHeaders: customHeaders,
            showsSaveResult: showsSaveResult,
            completion: completion
        )
    }

    func saveImage(_ image: UIImage) {
        saveImageToPhotos(image)
    }

    /// 一次保存多张原图（「下载全部」用这个）。
    ///
    /// 关键点：所有图片只在**一次** `performChanges` 里写进相册。
    /// 之前是每张图各调一次 `performChanges`，多张同时发起时系统只会让其中一个成功，
    /// 其余直接报错，表现就是「下载全部」只存进去一两张。
    /// 这里还补了两件事：写入前先确认相册写入权限；整批失败时逐张重试。
    func saveImages(
        _ items: [MediaImageSaveItem],
        showsDownloadStarted: Bool = true,
        showsSaveResult: Bool = true,
        completion: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        guard !items.isEmpty else {
            completion?(0, 0)
            return
        }
        if showsDownloadStarted {
            showDownloadStarted(mediaType: .photoAlbum)
        }
        Task {
            let payloads = await Self.downloadPayloads(items)
            guard !payloads.isEmpty else {
                Self.showBatchSaveToast(saved: 0, total: items.count, showsSaveResult: showsSaveResult)
                completion?(0, items.count)
                return
            }
            guard await Self.requestAddOnlyAuthorization() else {
                Self.showBatchSaveToast(saved: 0, total: items.count, showsSaveResult: showsSaveResult)
                completion?(0, items.count)
                return
            }
            var saved = await Self.writePayloadsToPhotos(payloads)
            if saved == 0, payloads.count > 1 {
                // 整批被拒（相册正忙 / 系统限流）时逐张再试一次。
                saved = await Self.writePayloadsOneByOne(payloads)
            }
            Self.showBatchSaveToast(saved: saved, total: items.count, showsSaveResult: showsSaveResult)
            completion?(saved, items.count)
        }
    }

    /// 把一条帖子里的图片/动图整理成批量保存项。
    static func imageSaveItem(for media: any UiMedia) -> MediaImageSaveItem? {
        switch onEnum(of: media) {
        case .image(let image):
            return MediaImageSaveItem(
                url: image.url,
                fallbackUrl: image.previewUrl,
                customHeaders: image.customHeaders
            )
        case .gif(let gif):
            return MediaImageSaveItem(url: gif.url, customHeaders: gif.customHeaders)
        default:
            return nil
        }
    }

    // MARK: - 批量保存的下载与写入

    nonisolated private static func downloadPayloads(_ items: [MediaImageSaveItem]) async -> [Data] {
        var results: [Int: Data] = [:]
        // 一次最多 4 张并发，既快又不会把图床打出 403。
        let chunkSize = 4
        var start = 0
        while start < items.count {
            let end = min(start + chunkSize, items.count)
            let base = start
            let slice = Array(items[start..<end])
            await withTaskGroup(of: (Int, Data?).self) { group in
                for (offset, item) in slice.enumerated() {
                    group.addTask {
                        (base + offset, await downloadPayload(item))
                    }
                }
                for await (index, data) in group {
                    if let data {
                        results[index] = data
                    }
                }
            }
            start = end
        }
        return results.keys.sorted().compactMap { results[$0] }
    }

    nonisolated private static func downloadPayload(_ item: MediaImageSaveItem) async -> Data? {
        for candidate in [item.url, item.fallbackUrl].compactMap({ $0 }) {
            guard let url = URL(string: candidate) else { continue }
            if let data = await fetchImageData(from: url, customHeaders: item.customHeaders), !data.isEmpty {
                return normalizedImageData(data)
            }
        }
        return nil
    }

    nonisolated private static func fetchImageData(
        from url: URL,
        customHeaders: [String: String]?
    ) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://m.weibo.cn/", forHTTPHeaderField: "Referer")
        customHeaders?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    nonisolated private static func requestAddOnlyAuthorization() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    /// 一次 performChanges 写入全部图片，返回成功写入的张数（整批失败返回 0）。
    nonisolated private static func writePayloadsToPhotos(_ payloads: [Data]) async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            PHPhotoLibrary.shared().performChanges {
                for payload in payloads {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: payload, options: nil)
                }
            } completionHandler: { success, error in
                continuation.resume(returning: (success && error == nil) ? payloads.count : 0)
            }
        }
    }

    nonisolated private static func writePayloadsOneByOne(_ payloads: [Data]) async -> Int {
        var saved = 0
        for payload in payloads {
            let count = await writePayloadsToPhotos([payload])
            if count > 0 {
                saved += 1
            }
        }
        return saved
    }

    nonisolated private static func showBatchSaveToast(
        saved: Int,
        total: Int,
        showsSaveResult: Bool
    ) {
        guard showsSaveResult else { return }
        let allSaved = total > 0 && saved >= total
        let base = saved > 0
            ? MediaSaveType.photoAlbum.title(success: true)
            : MediaSaveType.image.title(success: false)
        let title = total > 1 ? "\(base) (\(saved)/\(total))" : base
        DispatchQueue.main.async {
            Drops.show(
                .init(
                    title: title,
                    icon: UIImage(fontAwesome: allSaved ? .circleCheck : .circleExclamation)
                )
            )
        }
    }

    func saveVideo(
        url: String,
        customHeaders: [String: String]? = nil,
        showsDownloadStarted: Bool = true,
        showsSaveResult: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard let remoteUrl = URL(string: url),
              remoteUrl.pathExtension.lowercased() != "m3u8" else {
            finishSave(success: false, mediaType: .video, showsSaveResult: showsSaveResult, completion: completion)
            return
        }

        if showsDownloadStarted {
            showDownloadStarted(mediaType: .video)
        }

        if let cachedFileURL = completeCachedVideoFileURL(for: remoteUrl) {
            saveVideoFileToPhotos(
                cachedFileURL,
                showsSaveResult: showsSaveResult,
                completion: completion
            )
            return
        }

        downloadRemoteVideoToPhotos(
            from: remoteUrl,
            customHeaders: customHeaders,
            showsSaveResult: showsSaveResult,
            completion: completion
        )
    }

    func saveFile(
        url: String,
        fileName: String,
        customHeaders: [String: String]? = nil,
        showsDownloadStarted: Bool = true,
        showsSaveResult: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard let remoteUrl = URL(string: url) else {
            finishSave(success: false, mediaType: .file, showsSaveResult: showsSaveResult, completion: completion)
            return
        }

        if showsDownloadStarted {
            showDownloadStarted(mediaType: .file)
        }
        downloadRemoteFileForExport(
            from: remoteUrl,
            fileName: fileName,
            customHeaders: customHeaders,
            showsSaveResult: showsSaveResult,
            completion: completion
        )
    }

    private func saveRemoteOriginalDataToPhotos(
        from url: URL,
        customHeaders: [String: String]?,
        showsSaveResult: Bool,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        KingfisherManager.shared.downloader.downloadImage(with: url, options: kingfisherOptions(customHeaders: customHeaders), progressBlock: nil) { result in
            switch result {
            case .success(let v):
                self.saveOriginalDataToPhotos(
                    v.originalData,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
            case .failure:
                // Kingfisher 拿不到时（防盗链 403、Content-Type 不是图片、超时等）
                // 用 URLSession 带上 Referer/UA 再试一次，很多图床只认这两个头。
                self.downloadOriginalDataDirectly(from: url, customHeaders: customHeaders) { data in
                    guard let data else {
                        self.finishSave(
                            success: false,
                            mediaType: .image,
                            showsSaveResult: showsSaveResult,
                            completion: completion
                        )
                        return
                    }
                    self.saveOriginalDataToPhotos(
                        data,
                        showsSaveResult: showsSaveResult,
                        completion: completion
                    )
                }
            }
        }
    }

    /// 兜底下载：不经过 Kingfisher 的图片校验，直接取原始字节。
    private func downloadOriginalDataDirectly(
        from url: URL,
        customHeaders: [String: String]?,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
        }
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue("https://m.weibo.cn/", forHTTPHeaderField: "Referer")
        }
        customHeaders?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  !data.isEmpty else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }

    private func completeCachedVideoFileURL(for url: URL) -> URL? {
        let filePath = VideoCacheManager.cachedFilePath(for: url)
        guard FileManager.default.fileExists(atPath: filePath),
              CachedVideoConfiguration.load(forVideoFilePath: filePath)?.isComplete == true else {
            return nil
        }
        return URL(fileURLWithPath: filePath)
    }

    private func downloadRemoteVideoToPhotos(
        from url: URL,
        customHeaders: [String: String]?,
        showsSaveResult: Bool,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        var request = URLRequest(url: url)
        customHeaders?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            guard error == nil, let temporaryURL else {
                self.finishSave(
                    success: false,
                    mediaType: .video,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
                return
            }

            let fileExtension = AppleMediaFileExtension.video(url: url, response: response)
            let targetURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("flare-video-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)

            do {
                try FileManager.default.copyItem(at: temporaryURL, to: targetURL)
                self.saveVideoFileToPhotos(
                    targetURL,
                    removeWhenDone: true,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
            } catch {
                self.finishSave(
                    success: false,
                    mediaType: .video,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
            }
        }.resume()
    }

    private func downloadRemoteFileForExport(
        from url: URL,
        fileName: String,
        customHeaders: [String: String]?,
        showsSaveResult: Bool,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        var request = URLRequest(url: url)
        customHeaders?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            guard error == nil,
                  let temporaryURL,
                  Self.isSuccessfulHTTPResponse(response) else {
                self.finishSave(
                    success: false,
                    mediaType: .file,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
                return
            }

            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("flare-file-\(UUID().uuidString)", isDirectory: true)
            let sourceName = fileName.trimmedNonEmpty
                ?? response?.suggestedFilename?.trimmedNonEmpty
                ?? url.lastPathComponent.trimmedNonEmpty
                ?? "file"
            let exportURL = exportDirectory
                .appendingPathComponent(
                    MediaFileNamePolicy.shared.safeDownloadFileName(value: sourceName, fallback: "file")
                )

            do {
                try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporaryURL, to: exportURL)
                self.presentFileExportPicker(
                    fileURL: exportURL,
                    cleanupDirectory: exportDirectory,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
            } catch {
                try? FileManager.default.removeItem(at: exportDirectory)
                self.finishSave(
                    success: false,
                    mediaType: .file,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
            }
        }.resume()
    }

    nonisolated private func saveOriginalDataToPhotos(
        _ data: Data,
        showsSaveResult: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        // Photos 对 webp / 部分 HEIC 变体支持不好，直接塞原始字节会整条失败。
        // 能解码成 UIImage 但格式不认识的，先转成 JPEG 再存。
        let payload = Self.normalizedImageData(data)
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: payload, options: nil)
        } completionHandler: { success, error in
            self.finishSave(
                success: success && error == nil,
                mediaType: .image,
                showsSaveResult: showsSaveResult,
                completion: completion
            )
        }
    }

    /// 只放行 Photos 认识的格式（JPEG/PNG/GIF/HEIC），其余转成 JPEG。
    nonisolated private static func normalizedImageData(_ data: Data) -> Data {
        if data.starts(with: [0xFF, 0xD8]) ||          // JPEG
            data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || // PNG
            data.starts(with: [0x47, 0x49, 0x46]) {    // GIF
            return data
        }
        guard let image = UIImage(data: data) else {
            return data
        }
        return image.jpegData(compressionQuality: 0.95) ?? data
    }

    nonisolated private func saveImageToPhotos(_ image: UIImage) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        } completionHandler: { success, error in
            self.showSaveResult(success: success && error == nil)
        }
    }

    nonisolated private func saveVideoFileToPhotos(
        _ fileURL: URL,
        removeWhenDone: Bool = false,
        showsSaveResult: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: fileURL, options: nil)
        } completionHandler: { success, error in
            if removeWhenDone {
                try? FileManager.default.removeItem(at: fileURL)
            }
            self.finishSave(
                success: success && error == nil,
                mediaType: .video,
                showsSaveResult: showsSaveResult,
                completion: completion
            )
        }
    }

    nonisolated private static func isSuccessfulHTTPResponse(_ response: URLResponse?) -> Bool {
        guard let response = response as? HTTPURLResponse else {
            return true
        }
        return (200..<300).contains(response.statusCode)
    }

    private func kingfisherOptions(customHeaders: [String: String]?) -> KingfisherOptionsInfo {
        guard let customHeaders, !customHeaders.isEmpty else {
            return []
        }
        return [.requestModifier(AnyModifier { request in
            var request = request
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            return request
        })]
    }

    nonisolated private func finishSave(
        success: Bool,
        mediaType: MediaSaveType = .image,
        showsSaveResult: Bool,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        if showsSaveResult {
            showSaveResult(success: success, mediaType: mediaType)
        }
        completion?(success)
    }
    
    nonisolated private func showSaveResult(success: Bool, mediaType: MediaSaveType = .image) {
        DispatchQueue.main.async {
            Drops.show(
                .init(
                    title: mediaType.title(success: success),
                    icon: UIImage(fontAwesome: success ? .circleCheck : .circleExclamation)
                )
            )
        }
    }

    nonisolated private func showDownloadStarted(mediaType: MediaSaveType) {
        DispatchQueue.main.async {
            Drops.show(
                .init(
                    title: mediaType.downloadStartedTitle,
                    icon: .init(fontAwesome: FontAwesomeIcon.circleDown)
                )
            )
        }
    }

    nonisolated private static func showPreparingMediaNotification() {
        DispatchQueue.main.async {
            Drops.show(
                .init(
                    title: String(localized: "notification_prepare_media_started", defaultValue: "Preparing media"),
                    icon: .init(fontAwesome: FontAwesomeIcon.circleDown)
                )
            )
        }
    }

    nonisolated private func presentFileExportPicker(
        fileURL: URL,
        cleanupDirectory: URL,
        showsSaveResult: Bool,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        Task { @MainActor in
            guard let presenter = Self.topViewController() else {
                try? FileManager.default.removeItem(at: cleanupDirectory)
                self.finishSave(
                    success: false,
                    mediaType: .file,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
                return
            }

            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            picker.delegate = self
            self.pendingFileExports[ObjectIdentifier(picker)] =
                PendingFileExport(
                    cleanupDirectory: cleanupDirectory,
                    showsSaveResult: showsSaveResult,
                    completion: completion
                )
            presenter.present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let pendingExport = cleanupFileExport(for: controller)
        finishSave(
            success: true,
            mediaType: .file,
            showsSaveResult: pendingExport?.showsSaveResult ?? true,
            completion: pendingExport?.completion
        )
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let pendingExport = cleanupFileExport(for: controller)
        pendingExport?.completion?(false)
    }

    private func cleanupFileExport(for controller: UIDocumentPickerViewController) -> PendingFileExport? {
        let identifier = ObjectIdentifier(controller)
        guard let pendingExport = pendingFileExports.removeValue(forKey: identifier) else {
            return nil
        }
        try? FileManager.default.removeItem(at: pendingExport.cleanupDirectory)
        return pendingExport
    }

    private static func topViewController() -> UIViewController? {
        let rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }?
            .rootViewController
        return topViewController(from: rootViewController)
    }

    private static func topViewController(from viewController: UIViewController?) -> UIViewController? {
        if let navigationController = viewController as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController)
        }
        if let tabBarController = viewController as? UITabBarController {
            return topViewController(from: tabBarController.selectedViewController)
        }
        if let presentedViewController = viewController?.presentedViewController {
            return topViewController(from: presentedViewController)
        }
        return viewController
    }
}

private struct PendingFileExport {
    let cleanupDirectory: URL
    let showsSaveResult: Bool
    let completion: (@Sendable (Bool) -> Void)?
}

private enum MediaSaveType {
    case image
    case video
    case file
    case photoAlbum

    func title(success: Bool) -> String {
        switch self {
        case .image:
            return .init(localized: success ? "notification_save_image_success" : "notification_save_image_error")
        case .video:
            return .init(localized: success ? "notification_save_video_success" : "notification_save_video_error")
        case .file:
            if success {
                return String(localized: "notification_save_file_success", defaultValue: "Saved to Files")
            }
            return String(localized: "notification_save_file_error", defaultValue: "Failed to save file")
        case .photoAlbum:
            if success {
                return String(localized: "notification_save_photo_album_success", defaultValue: "Saved to Photos")
            }
            return String(localized: "notification_save_file_error", defaultValue: "Failed to save file")
        }
    }

    var downloadStartedTitle: String {
        switch self {
        case .image:
            return String(localized: "notification_download_file_started", defaultValue: "Download started")
        case .video:
            return .init(localized: "notification_download_video_started")
        case .file:
            return String(localized: "notification_download_file_started", defaultValue: "Download started")
        case .photoAlbum:
            return String(localized: "notification_download_file_started", defaultValue: "Download started")
        }
    }
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct CachedVideoConfiguration: Decodable {
    let info: CachedVideoInfo?
    let fragments: [CachedVideoFragment]

    static func load(forVideoFilePath filePath: String) -> CachedVideoConfiguration? {
        let configurationURL = URL(fileURLWithPath: filePath).appendingPathExtension("cfg")
        guard let data = try? Data(contentsOf: configurationURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedVideoConfiguration.self, from: data)
    }

    var isComplete: Bool {
        guard let contentLength = info?.contentLength, contentLength > 0 else {
            return false
        }

        let sortedFragments = fragments.sorted { $0.location < $1.location }
        var coveredUpperBound = 0

        for fragment in sortedFragments {
            if fragment.location > coveredUpperBound {
                return false
            }
            coveredUpperBound = max(coveredUpperBound, fragment.location + fragment.length)
            if coveredUpperBound >= contentLength {
                return true
            }
        }

        return false
    }
}

private struct CachedVideoInfo: Decodable {
    let contentLength: Int
}

private struct CachedVideoFragment: Decodable {
    let location: Int
    let length: Int
}
