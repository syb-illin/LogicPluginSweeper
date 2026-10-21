import Foundation

enum AppResources {
    static let bundle: Bundle = {
        let bundleName = "LogicPluginSweeper_LogicPluginSweeper.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        ].compactMap { $0 }

        for candidate in candidates {
            let bundleURL = candidate.appendingPathComponent(bundleName, isDirectory: true)
            if let resourceBundle = Bundle(url: bundleURL) {
                return resourceBundle
            }
        }

        return Bundle.main
    }()

    static func url(forResource name: String, withExtension fileExtension: String, subdirectory: String? = nil) -> URL? {
        if let subdirectory,
           let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory) {
            return url
        }

        return bundle.url(forResource: name, withExtension: fileExtension)
    }
}
