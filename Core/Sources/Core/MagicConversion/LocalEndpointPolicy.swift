import Foundation

/// 打った文章を外部に送らないための決まり（azooKey Medical で追加）。
/// AI のサーバーには、この Mac の中（127.0.0.1・localhost・::1）にだけ接続する。
/// アプリにはネット通信の権限があるが、接続先をここで確かめてから送る
public enum LocalEndpointPolicy {
    public static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return allowedHosts.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    /// AI のサーバーとの通信に使う。転送（リダイレクト）に従わず、システムのプロキシも使わない。
    /// この Mac の中のサーバーが外部への転送を返しても、文章を外部へ送り直さないため
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 180
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum LocalOnlyError: LocalizedError, Sendable {
    /// この Mac の外のサーバーが指定された
    case nonLocalEndpoint(String)
    /// 外部からのダウンロードは行わない
    case externalDownloadDisabled
    /// Ollama のクラウドのモデルなど、サーバーが文章をこの Mac の外へ送るモデル
    case remoteModel(String)

    public var errorDescription: String? {
        switch self {
        case .nonLocalEndpoint(let endpoint):
            return "この Mac の中のサーバーにしか接続しません（指定された接続先: \(endpoint)）"
        case .externalDownloadDisabled:
            return "azooKey Medical では、外部からのダウンロードは行いません"
        case .remoteModel(let model):
            return "「\(model)」は、文章がこの Mac の外（Ollama のクラウドなど）に送られるモデルなので使いません"
        }
    }
}
