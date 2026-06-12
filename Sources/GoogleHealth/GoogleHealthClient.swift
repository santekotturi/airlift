import Foundation

enum GoogleHealthError: Error, LocalizedError {
    case unauthorized
    case http(status: Int, body: String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The access token was rejected (HTTP 401)."
        case .http(let status, let body):
            return "Google Health API error (HTTP \(status)): \(body)"
        case .decoding(let error):
            return "Failed to decode the sleep response: \(error.localizedDescription)"
        }
    }
}

/// Thin client over the Google Health API sleep endpoints (PRD §6.2).
///
/// Stateless w.r.t. auth: callers pass a valid access token. A `401` surfaces as
/// `.unauthorized` so the sync engine can refresh once and retry; `5xx` is
/// wrapped as `RetryableError` and retried with backoff here.
struct GoogleHealthClient {
    static let baseURL = URL(string: "https://health.googleapis.com/v4/")!

    private let session: URLSession
    private let backoff: BackoffPolicy

    init(session: URLSession = .shared, backoff: BackoffPolicy = .sleepReads) {
        self.session = session
        self.backoff = backoff
    }

    /// Fetches finalized sleep sessions whose civil end time is on/after `from`.
    /// Uses `dataPoints:list` with a civil-time filter — the workhorse read for
    /// sleep (PRD §6.2). Pages are followed until exhausted.
    ///
    /// `onRawPage` (optional) receives each page's raw JSON before decoding — used
    /// during bring-up to verify the pre-GA wire schema against real data.
    func fetchSleepSessions(
        since from: Date,
        accessToken: String,
        calendar: Calendar = .current,
        onRawPage: (@Sendable (Data) -> Void)? = nil
    ) async throws -> [SleepSession] {
        let filterDate = Self.civilDateString(from, calendar: calendar)
        var sessions: [SleepSession] = []
        var pageToken: String?

        repeat {
            let page = try await withRetry(policy: backoff) {
                try await self.fetchPage(filterDate: filterDate, pageToken: pageToken, accessToken: accessToken, onRaw: onRawPage)
            }
            sessions.append(contentsOf: page.mapped())
            pageToken = page.nextPageToken
        } while pageToken != nil

        return sessions
    }

    private func fetchPage(filterDate: String, pageToken: String?, accessToken: String, onRaw: (@Sendable (Data) -> Void)?) async throws -> SleepDataPointsResponse {
        try await fetchDecodedPage(
            dataTypePath: "sleep",
            filter: "sleep.interval.civil_end_time >= \"\(filterDate)\"",
            pageToken: pageToken,
            accessToken: accessToken,
            onRaw: onRaw
        )
    }

    // MARK: - Quantity metrics (HR, HRV, SpO2, respiratory rate, steps, …)

    /// Fetches quantity data points for a `MetricKind`, paged, with the same
    /// retry/backoff as sleep.
    ///
    /// Tries the civil-time filter first; not every type supports that filter
    /// member (steps rejects it), so a 400 INVALID_DATA_POINT_FILTER falls back
    /// to unfiltered paging — pages arrive newest-first, so paging stops once a
    /// page reaches back past `from`, and older samples are trimmed client-side.
    func fetchMetricSamples(
        _ kind: MetricKind,
        since from: Date,
        accessToken: String,
        calendar: Calendar = .current,
        onRawPage: (@Sendable (Data) -> Void)? = nil
    ) async throws -> [MetricSample] {
        let filterDate = Self.civilDateString(from, calendar: calendar)
        let filter = "\(kind.filterMember).interval.civil_end_time >= \"\(filterDate)\""
        do {
            return try await fetchMetricPages(kind, filter: filter, cutoff: nil, accessToken: accessToken, onRawPage: onRawPage)
        } catch GoogleHealthError.http(let status, let body)
            where status == 400 && body.contains("INVALID_DATA_POINT_FILTER") {
            Log.api.notice("\(kind.rawValue): civil-time filter unsupported — paging unfiltered with client-side cutoff")
            return try await fetchMetricPages(kind, filter: nil, cutoff: from, accessToken: accessToken, onRawPage: onRawPage)
        }
    }

    private func fetchMetricPages(
        _ kind: MetricKind,
        filter: String?,
        cutoff: Date?,
        accessToken: String,
        onRawPage: (@Sendable (Data) -> Void)?
    ) async throws -> [MetricSample] {
        var samples: [MetricSample] = []
        var pageToken: String?
        var pages = 0
        // Fitbit Air heart rate is ~3s granularity → ~56 pages/day at 500/page;
        // 600 pages covers a 7-day backfill window with headroom.
        let maxPages = 600

        repeat {
            let page: QuantityDataPointsResponse = try await withRetry(policy: backoff) {
                try await self.fetchDecodedPage(
                    dataTypePath: kind.googleDataTypePath,
                    filter: filter,
                    pageSize: 500, // server default is 50 — far too small for intraday HR
                    pageToken: pageToken,
                    accessToken: accessToken,
                    onRaw: onRawPage
                )
            }
            samples.append(contentsOf: page.mapped(kind: kind))
            pageToken = page.nextPageToken
            pages += 1

            if let cutoff, let oldest = page.oldestStart(kind: kind), oldest < cutoff {
                break // newest-first: everything further back is out of window
            }
            if pages >= maxPages {
                Log.api.notice("\(kind.rawValue): stopped after \(maxPages) pages — older data left unfetched")
                break
            }
        } while pageToken != nil

        if let cutoff {
            samples.removeAll { $0.end < cutoff }
        }
        return samples
    }

    // MARK: - Discovery (debug bring-up)

    /// Raw `GET users/me/dataTypes` — the server's own data-type catalog.
    /// Used during bring-up to learn the exact type names/paths instead of
    /// guessing them; the payload goes straight to the dump folder.
    func fetchDataTypeCatalog(accessToken: String) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("users/me/dataTypes"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200..<300: return data
        case 401: throw GoogleHealthError.unauthorized
        default: throw GoogleHealthError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Raw `dataPoints` GET against an arbitrary type path, optionally with no
    /// filter. Returns the HTTP status and body verbatim — non-2xx is *data*
    /// here, not an error (a 400/404 body tells us whether the type exists).
    /// 401 still throws so the caller can refresh and retry.
    func probeDataPoints(dataTypePath: String, filterDate: String?, accessToken: String) async throws -> (status: Int, body: Data) {
        let endpoint = Self.baseURL.appendingPathComponent("users/me/dataTypes/\(dataTypePath)/dataPoints")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if let filterDate {
            components.queryItems = [
                URLQueryItem(name: "filter", value: "\(dataTypePath).interval.civil_end_time >= \"\(filterDate)\""),
            ]
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 { throw GoogleHealthError.unauthorized }
        return (status, data)
    }

    /// Raw GET against an arbitrary API path ("users/me/devices") — discovery
    /// probing for endpoints the pre-GA docs don't list yet. Status is data;
    /// only 401 throws (so the caller can refresh and retry).
    func probeRawPath(_ path: String, accessToken: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 { throw GoogleHealthError.unauthorized }
        return (status, data)
    }

    // MARK: - Shared transport

    private func fetchDecodedPage<Response: Decodable>(
        dataTypePath: String,
        filter: String?,
        pageSize: Int? = nil,
        pageToken: String?,
        accessToken: String,
        onRaw: (@Sendable (Data) -> Void)?
    ) async throws -> Response {
        let request = buildRequest(dataTypePath: dataTypePath, filter: filter, pageSize: pageSize, pageToken: pageToken, accessToken: accessToken)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RetryableError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200..<300:
            onRaw?(data)
            do {
                return try JSONDecoder.googleHealth.decode(Response.self, from: data)
            } catch {
                throw GoogleHealthError.decoding(error)
            }
        case 401:
            throw GoogleHealthError.unauthorized
        case 500..<600:
            // Known intermittent 500s during the migration period — let backoff retry.
            throw RetryableError.serverError(status: status)
        default:
            throw GoogleHealthError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func buildRequest(dataTypePath: String, filter: String?, pageSize: Int? = nil, pageToken: String?, accessToken: String) -> URLRequest {
        let endpoint = Self.baseURL.appendingPathComponent("users/me/dataTypes/\(dataTypePath)/dataPoints")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = []
        if let filter {
            query.append(URLQueryItem(name: "filter", value: filter))
        }
        if let pageSize {
            query.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
        }
        if let pageToken {
            query.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = query.isEmpty ? nil : query

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func civilDateString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
