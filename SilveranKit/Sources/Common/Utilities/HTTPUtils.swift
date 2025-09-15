import Foundation

public enum HTTPRequestError: Error {
    case invalidURL(String)
    case malformedResponse
    case unauthorized
    case notFound
    case unexpectedStatus(Int)
    case networkFailure(Error)
}

struct HTTPResponse {
    let data: Data
    let response: HTTPURLResponse

    var statusCode: Int { response.statusCode }
}

private let defaultSuccessfulStatusCodes: Set<Int> = Set(200..<300)

private func resolvedAllowedStatusCodes(_ additional: Set<Int>?) -> Set<Int> {
    guard let additional else { return defaultSuccessfulStatusCodes }
    return defaultSuccessfulStatusCodes.union(additional)
}

func httpGet(
    _ urlString: String,
    headers: [String: String] = [:],
    queryParameters: [String: String] = [:],
    session: URLSession = .shared,
    debug: Bool = false,
    allowedStatusCodes: Set<Int>? = nil
) async throws -> HTTPResponse {
    try await httpRequest(
        method: "GET",
        urlString: urlString,
        headers: headers,
        queryParameters: queryParameters,
        body: nil,
        session: session,
        debug: debug,
        allowedStatusCodes: resolvedAllowedStatusCodes(allowedStatusCodes)
    )
}

func httpPost(
    _ urlString: String,
    headers: [String: String] = [:],
    queryParameters: [String: String] = [:],
    formParameters: [String: String] = [:],
    body: Data? = nil,
    session: URLSession = .shared,
    debug: Bool = false,
    allowedStatusCodes: Set<Int>? = nil
) async throws -> HTTPResponse {
    if body != nil && !formParameters.isEmpty {
        assertionFailure("Provide either body or formParameters when calling httpPost.")
    }
    let payload: Data?
    if let body {
        payload = body
    } else if !formParameters.isEmpty {
        var components = URLComponents()
        components.queryItems =
            formParameters
            .sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        payload = components.percentEncodedQuery?.data(using: .utf8)
    } else {
        payload = nil
    }

    return try await httpRequest(
        method: "POST",
        urlString: urlString,
        headers: headers,
        queryParameters: queryParameters,
        body: payload,
        session: session,
        debug: debug,
        allowedStatusCodes: resolvedAllowedStatusCodes(allowedStatusCodes)
    )
}

func httpPut(
    _ urlString: String,
    headers: [String: String] = [:],
    queryParameters: [String: String] = [:],
    body: Data? = nil,
    session: URLSession = .shared,
    debug: Bool = false,
    allowedStatusCodes: Set<Int>? = nil
) async throws -> HTTPResponse {
    try await httpRequest(
        method: "PUT",
        urlString: urlString,
        headers: headers,
        queryParameters: queryParameters,
        body: body,
        session: session,
        debug: debug,
        allowedStatusCodes: resolvedAllowedStatusCodes(allowedStatusCodes)
    )
}

func httpPatch(
    _ urlString: String,
    headers: [String: String] = [:],
    queryParameters: [String: String] = [:],
    body: Data? = nil,
    session: URLSession = .shared,
    debug: Bool = false,
    allowedStatusCodes: Set<Int>? = nil
) async throws -> HTTPResponse {
    try await httpRequest(
        method: "PATCH",
        urlString: urlString,
        headers: headers,
        queryParameters: queryParameters,
        body: body,
        session: session,
        debug: debug,
        allowedStatusCodes: resolvedAllowedStatusCodes(allowedStatusCodes)
    )
}

func httpDelete(
    _ urlString: String,
    headers: [String: String] = [:],
    queryParameters: [String: String] = [:],
    body: Data? = nil,
    session: URLSession = .shared,
    debug: Bool = false,
    allowedStatusCodes: Set<Int>? = nil
) async throws -> HTTPResponse {
    try await httpRequest(
        method: "DELETE",
        urlString: urlString,
        headers: headers,
        queryParameters: queryParameters,
        body: body,
        session: session,
        debug: debug,
        allowedStatusCodes: resolvedAllowedStatusCodes(allowedStatusCodes)
    )
}

func urlWithQueryParameters(
    _ url: URL,
    queryParameters: [String: String]
) throws -> URL {
    let resolvedString = try resolveURLString(
        url.absoluteString,
        adding: queryParameters
    )

    guard let resolvedURL = URL(string: resolvedString) else {
        throw HTTPRequestError.invalidURL(resolvedString)
    }
    return resolvedURL
}

private func httpRequest(
    method: String,
    urlString: String,
    headers: [String: String],
    queryParameters: [String: String],
    body: Data?,
    session: URLSession,
    debug: Bool,
    allowedStatusCodes: Set<Int>
) async throws -> HTTPResponse {
    let resolvedURLString = try resolveURLString(urlString, adding: queryParameters)
    guard let url = URL(string: resolvedURLString) else {
        throw HTTPRequestError.invalidURL(resolvedURLString)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.httpBody = body

    let (data, response) = try await session.data(for: request)

    if debug, let responseString = String(data: data, encoding: .utf8) {
        debugLog("[HTTPUtils] raw response: \(responseString)")
    }

    guard let httpResponse = response as? HTTPURLResponse else {
        throw HTTPRequestError.malformedResponse
    }

    guard allowedStatusCodes.contains(httpResponse.statusCode) else {
        logHTTPFailure(
            method: method,
            url: httpResponse.url ?? url,
            statusCode: httpResponse.statusCode,
            data: data
        )
        switch httpResponse.statusCode {
            case 401, 403:
                throw HTTPRequestError.unauthorized
            case 404:
                throw HTTPRequestError.notFound
            default:
                throw HTTPRequestError.unexpectedStatus(httpResponse.statusCode)
        }
    }
    return HTTPResponse(data: data, response: httpResponse)
}

private func resolveURLString(
    _ urlString: String,
    adding queryParameters: [String: String]
) throws -> String {
    guard !queryParameters.isEmpty else {
        return urlString
    }

    guard var components = URLComponents(string: urlString) else {
        throw HTTPRequestError.invalidURL(urlString)
    }

    let newItems =
        queryParameters
        .sorted(by: { $0.key < $1.key })
        .map { URLQueryItem(name: $0.key, value: $0.value) }

    if components.queryItems?.isEmpty == false {
        components.queryItems?.append(contentsOf: newItems)
    } else {
        components.queryItems = newItems
    }

    guard let resolvedURL = components.url else {
        throw HTTPRequestError.invalidURL(urlString)
    }
    return resolvedURL.absoluteString
}

private func logHTTPFailure(method: String, url: URL, statusCode: Int, data: Data) {
    let prefix = "HTTP \(method) \(url.absoluteString) failed [\(statusCode)]"
    if let body = String(data: data, encoding: .utf8), !body.isEmpty {
        debugLog("[HTTPUtils] \(prefix): \(body)")
    } else if !data.isEmpty {
        debugLog("[HTTPUtils] \(prefix): \(data.count) bytes")
    } else {
        debugLog("[HTTPUtils] \(prefix): <empty body>")
    }
}

func postFormData(url: String, formFields: [String: String]) async -> Data? {
    guard let endpoint = URL(string: url) else {
        debugLog("[HTTPUtils] Invalid URL: \(url)")
        return nil
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    var body = ""

    for (key, value) in formFields {
        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n"
        body += "\(value)\r\n"
    }

    body += "--\(boundary)--\r\n"

    guard let bodyData = body.data(using: .utf8) else {
        debugLog("[HTTPUtils] Failed to encode body")
        return nil
    }

    request.setValue(
        "multipart/form-data; boundary=\(boundary)",
        forHTTPHeaderField: "Content-Type"
    )
    request.httpBody = bodyData

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            debugLog("[HTTPUtils] Invalid response")
            return nil
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            debugLog("[HTTPUtils] Bad status: \(httpResponse.statusCode)")
            return nil
        }
        return data
    } catch {
        debugLog("[HTTPUtils] Error: \(error)")
        return nil
    }
}
