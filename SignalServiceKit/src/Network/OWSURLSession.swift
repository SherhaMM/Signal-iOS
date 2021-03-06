//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

public enum HTTPVerb {
    case get
    case post
    case put
    case head

    public var httpMethod: String {
        switch self {
        case .get:
            return "GET"
        case .post:
            return "POST"
        case .put:
            return "PUT"
        case .head:
            return "HEAD"
        }
    }
}

private var URLSessionProgressBlockHandle: UInt8 = 0

// TODO: If we use OWSURLSession more, we'll need to add support for more features, e.g.:
//
// * Download tasks (to memory, to disk).
// * Observing download progress.
// * Redirects.
@objc
public class OWSURLSession: NSObject {

    private static let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.underlyingQueue = .global()
        return queue
    }()

    private let baseUrl: URL?

    private let configuration: URLSessionConfiguration

    // TODO: Replace AFSecurityPolicy.
    private let securityPolicy: AFSecurityPolicy

    private var extraHeaders = [String: String]()

    @objc
    public let censorshipCircumventionHost: String?

    @objc
    public var isUsingCensorshipCircumvention: Bool {
        censorshipCircumventionHost != nil
    }

    @objc(addExtraHeader:withValue:)
    public func addExtraHeader(_ header: String, value: String) {
        owsAssertDebug(!header.isEmpty)
        owsAssertDebug(!value.isEmpty)
        owsAssertDebug(extraHeaders[header] == nil)

        extraHeaders[header] = value
    }

    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: self, delegateQueue: Self.operationQueue)
    }()

    @objc
    public static func defaultSecurityPolicy() -> AFSecurityPolicy {
        AFSecurityPolicy.default()
    }

    @objc
    public static func signalServiceSecurityPolicy() -> AFSecurityPolicy {
        OWSHTTPSecurityPolicy.shared()
    }

    @objc
    public static func defaultURLSessionConfiguration() -> URLSessionConfiguration {
        URLSessionConfiguration.ephemeral
    }

    @objc
    public init(baseUrl: URL?,
                securityPolicy: AFSecurityPolicy,
                configuration: URLSessionConfiguration,
                censorshipCircumventionHost: String? = nil) {
        self.baseUrl = baseUrl
        self.securityPolicy = securityPolicy
        self.configuration = configuration
        self.censorshipCircumventionHost = censorshipCircumventionHost

        super.init()
    }

    typealias Response = (response: HTTPURLResponse, data: Data?)
    typealias ProgressBlock = (Progress) -> Void

    func uploadTaskPromise(_ urlString: String,
                           verb: HTTPVerb,
                           headers: [String: String]? = nil,
                           data requestData: Data,
                           progressBlock: ProgressBlock? = nil) -> Promise<Response> {
        firstly(on: .global()) { () -> Promise<Response> in
            let request = try self.buildRequest(urlString, verb: verb, headers: headers)
            return self.uploadTaskPromise(request: request, data: requestData, progressBlock: progressBlock)
        }
    }

    func uploadTaskPromise(request: URLRequest,
                           data requestData: Data,
                           progressBlock: ProgressBlock? = nil) -> Promise<Response> {

        let (promise, resolver) = Promise<Response>.pending()
        var taskReference: URLSessionDataTask?
        let task = session.uploadTask(with: request, from: requestData) { (responseData: Data?, response: URLResponse?, error: Error?) in
            if let task = taskReference {
                self.setProgressBlock(nil, forTask: task)
            } else {
                owsFailDebug("Missing task.")
            }
            Self.handleTaskCompletion(resolver: resolver, responseData: responseData, response: response, error: error)
        }
        taskReference = task
        setProgressBlock(progressBlock, forTask: task)
        task.resume()
        return promise
    }

    func uploadTaskPromise(_ urlString: String,
                           verb: HTTPVerb,
                           headers: [String: String]? = nil,
                           dataUrl: URL,
                           progressBlock: ProgressBlock? = nil) -> Promise<Response> {
        firstly(on: .global()) { () -> Promise<Response> in
            let request = try self.buildRequest(urlString, verb: verb, headers: headers)
            return self.uploadTaskPromise(request: request, dataUrl: dataUrl, progressBlock: progressBlock)
        }
    }

    func uploadTaskPromise(request: URLRequest,
                           dataUrl: URL,
                           progressBlock: ProgressBlock? = nil) -> Promise<Response> {

        let (promise, resolver) = Promise<Response>.pending()
        var taskReference: URLSessionDataTask?
        let task = session.uploadTask(with: request, fromFile: dataUrl) { (responseData: Data?, response: URLResponse?, error: Error?) in
            if let task = taskReference {
                self.setProgressBlock(nil, forTask: task)
            } else {
                owsFailDebug("Missing task.")
            }
            Self.handleTaskCompletion(resolver: resolver, responseData: responseData, response: response, error: error)
        }
        taskReference = task
        setProgressBlock(progressBlock, forTask: task)
        task.resume()
        return promise
    }

    func dataTaskPromise(_ urlString: String,
                         verb: HTTPVerb,
                         headers: [String: String]? = nil,
                         body: Data?) -> Promise<Response> {
        firstly(on: .global()) { () -> Promise<Response> in
            let request = try self.buildRequest(urlString, verb: verb, headers: headers, body: body)
            return self.dataTaskPromise(request: request)
        }
    }

    func dataTaskPromise(request: URLRequest) -> Promise<Response> {

        let (promise, resolver) = Promise<Response>.pending()
        let task = session.dataTask(with: request) { (responseData: Data?, response: URLResponse?, error: Error?) in
            Self.handleTaskCompletion(resolver: resolver, responseData: responseData, response: response, error: error)
        }
        task.resume()
        return promise
    }

    private class func handleTaskCompletion(resolver: Resolver<Response>,
                                            responseData: Data?,
                                            response: URLResponse?,
                                            error: Error?) {
        if let error = error {
            if IsNetworkConnectivityFailure(error) {
                Logger.warn("Request failed: \(error)")
            } else {
                owsFailDebug("Request failed: \(error)")
            }
            resolver.reject(error)
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            resolver.reject(OWSAssertionError("Invalid response: \(type(of: response))."))
            return
        }
        resolver.fulfill((response: httpResponse, data: responseData))
    }

    // TODO: Add downloadTaskPromise().

    // MARK: -

    private func buildRequest(_ urlString: String,
                              verb: HTTPVerb,
                              headers: [String: String]? = nil,
                              body: Data? = nil) throws -> URLRequest {
        guard let url = buildUrl(urlString) else {
            throw OWSAssertionError("Invalid url.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = verb.httpMethod

        var headerSet = Set<String>()

        // Add the headers.
        if let headers = headers {
            for (headerField, headerValue) in headers {
                owsAssertDebug(!headerSet.contains(headerField.lowercased()))
                headerSet.insert(headerField.lowercased())

                request.addValue(headerValue, forHTTPHeaderField: headerField)

            }
        }

        // Add the "extra headers".
        for (headerField, headerValue) in extraHeaders {
            guard !headerSet.contains(headerField.lowercased()) else {
                owsFailDebug("Skipping redundant header: \(headerField)")
                continue
            }
            headerSet.insert(headerField.lowercased())

            request.addValue(headerValue, forHTTPHeaderField: headerField)
        }

        request.httpBody = body
        return request
    }

    private func buildUrl(_ urlString: String) -> URL? {
        guard let censorshipCircumventionHost = censorshipCircumventionHost else {
            // Censorship circumvention not active.
            guard let requestUrl = URL(string: urlString, relativeTo: baseUrl) else {
                owsFailDebug("Could not build URL.")
                return nil
            }
            return requestUrl
        }

        // Censorship circumvention active.
        guard !censorshipCircumventionHost.isEmpty else {
            owsFailDebug("Invalid censorshipCircumventionHost.")
            return nil
        }
        guard let baseUrl = baseUrl else {
            owsFailDebug("Censorship circumvention requires baseUrl.")
            return nil
        }

        if urlString.hasPrefix(censorshipCircumventionHost) {
            // urlString has expected protocol/host.
        } else if urlString.lowercased().hasPrefix("http") {
            // Censorship circumvention will work with relative URLs and
            // absolute URLs that match the expected protocol/host prefix.
            // Other absolute URLs should not be used with this session.
            owsFailDebug("Unexpected URL for censorship circumvention.")
        }

        guard let requestUrl = Self.buildUrl(urlString: urlString, baseUrl: baseUrl) else {
            owsFailDebug("Could not build URL.")
            return nil
        }
        return requestUrl
    }

    @objc(buildUrlWithString:baseUrl:)
    public class func buildUrl(urlString: String, baseUrl: URL?) -> URL? {
        guard let baseUrl = baseUrl else {
            guard let requestUrl = URL(string: urlString, relativeTo: nil) else {
                owsFailDebug("Could not build URL.")
                return nil
            }
            return requestUrl
        }

        // Ensure the base URL has a trailing "/".
        let safeBaseUrl: URL = (baseUrl.absoluteString.hasSuffix("/")
            ? baseUrl
            : baseUrl.appendingPathComponent(""))

        guard let requestComponents = URLComponents(string: urlString) else {
            owsFailDebug("Could not rewrite URL.")
            return nil
        }

        var finalComponents = URLComponents()

        // Use scheme and host from baseUrl.
        finalComponents.scheme = baseUrl.scheme
        finalComponents.host = baseUrl.host

        // Use query and fragement from the request.
        finalComponents.query = requestComponents.query
        finalComponents.fragment = requestComponents.fragment

        // Join the paths.
        finalComponents.path = (safeBaseUrl.path as NSString).appendingPathComponent(requestComponents.path)

        guard let finalUrlString = finalComponents.string else {
            owsFailDebug("Could not rewrite URL.")
            return nil
        }

        guard let finalUrl = URL(string: finalUrlString) else {
            owsFailDebug("Could not rewrite URL.")
            return nil
        }
        return finalUrl
    }

    typealias TaskIdentifier = Int
    typealias ProgressBlockMap = [TaskIdentifier: ProgressBlock]

    private let lock = UnfairLock()
    private var progressBlockMap = ProgressBlockMap()

    private func progressBlock(forTask task: URLSessionTask) -> ProgressBlock? {
        lock.withLock {
            self.progressBlockMap[task.taskIdentifier]
        }
    }

    private func setProgressBlock(_ progressBlock: ProgressBlock?,
                                  forTask task: URLSessionTask) {
        lock.withLock {
            if let progressBlock = progressBlock {
                self.progressBlockMap[task.taskIdentifier] = progressBlock
            } else {
                self.progressBlockMap.removeValue(forKey: task.taskIdentifier)
            }
        }
    }

    public typealias URLAuthenticationChallengeCompletion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    fileprivate func urlSession(didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping URLAuthenticationChallengeCompletion) {

        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
        var credential: URLCredential?

        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust {
            if securityPolicy.evaluateServerTrust(serverTrust, forDomain: challenge.protectionSpace.host) {
                credential = URLCredential(trust: serverTrust)
                disposition = .useCredential
            } else {
                disposition = .cancelAuthenticationChallenge
            }
        } else {
            disposition = .performDefaultHandling
        }

        completionHandler(disposition, credential)
    }
}

// MARK: -

extension OWSURLSession: URLSessionDelegate {

    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping URLAuthenticationChallengeCompletion) {
        urlSession(didReceive: challenge, completionHandler: completionHandler)
    }
}

// MARK: -

extension OWSURLSession: URLSessionTaskDelegate {

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping URLAuthenticationChallengeCompletion) {

        urlSession(didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let progressBlock = self.progressBlock(forTask: task) else {
            return
        }
        let progress = Progress(parent: nil, userInfo: nil)
        // TODO: We could check for NSURLSessionTransferSizeUnknown here.
        progress.totalUnitCount = totalBytesExpectedToSend
        progress.completedUnitCount = totalBytesSent
        progressBlock(progress)
    }
}
