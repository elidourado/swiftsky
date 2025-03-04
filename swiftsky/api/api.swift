//
//  api.swift
//  swiftsky
//

import Combine
import Foundation
import SwiftUI

struct AnyKey: CodingKey {
  var stringValue: String
  var intValue: Int?
  
  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }
  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}
struct xrpcErrorDescription: Error, LocalizedError, Decodable {
  let error: String?
  let message: String?
  var errorDescription: String? {
    message
  }
}

class Client {
  static let shared = Client()
  private let baseURL = "https://bsky.social/xrpc/"
  private let decoder: JSONDecoder
  public var user = AuthData()
  @AppStorage("did") public var did: String = ""
  @AppStorage("handle") public var handle: String = ""
  enum httpMethod {
    case get
    case post
  }
  init() {
    self.decoder = JSONDecoder()
    self.decoder.keyDecodingStrategy = .custom({keys in
      var last = keys.last!.stringValue
      if last.first == "$" {
        last.removeFirst()
      }
      return AnyKey(stringValue: last)!
    })
    self.decoder.dateDecodingStrategy = .custom({ decoder in
      let container = try decoder.singleValueContainer()
      let dateString = try container.decode(String.self)
      if let date = Formatter.iso8601withFractionalSeconds.date(from: dateString) {
        return date
      }
      if let date = Formatter.iso8601withTimeZone.date(from: dateString) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Cannot decode date string \(dateString)")
    })
  }
  public func postInit() {

    if let user = AuthData.load() {
      self.user = user
      let group = DispatchGroup()
      group.enter()
      Task {
        do {
          let session = try await xrpcSessionGet()
          if self.did == session.did, self.handle == session.handle {
            Auth.shared.needAuthorization = false
          }
        } catch {

        }
        group.leave()
      }
      group.wait()
    }
  }
  private func refreshSession() async -> Bool {
    do {
      let result: SessionRefreshOutput = try await self.fetch(
        endpoint: "com.atproto.server.refreshSession", httpMethod: .post,
        authorization: self.user.refreshJwt, params: Optional<Bool>.none, retry: false)
      self.user.accessJwt = result.accessJwt
      self.user.refreshJwt = result.refreshJwt
      self.handle = result.handle
      self.did = result.did
      self.user.save()
      return true
    } catch {
      if error is xrpcErrorDescription {
        print(error)
      }
    }
    return false
  }
  func fetch<T: Decodable, U: Encodable>(
    endpoint: String, httpMethod: httpMethod = .get, authorization: String? = nil, params: U? = nil,
    retry: Bool = true
  ) async throws -> T {
    guard var urlComponents = URLComponents(string: baseURL + endpoint) else {
      throw URLError(.badURL)
    }
    if httpMethod == .get, let params = params?.dictionary {
      urlComponents.queryItems = params.flatMap {
        if $0.hasSuffix("[]") {
          let name = $0
          return ($1 as! [Any]).map {
            URLQueryItem(name: name, value: "\($0)")
          }
        }
        return [URLQueryItem(name: $0, value: "\($1)")]
      }
    }
    guard let url = urlComponents.url else {
      throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.addValue("application/json", forHTTPHeaderField: "Accept")
    if let authorization {
      request.addValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
    }
    switch httpMethod {
    case .get:
      request.httpMethod = "GET"
    case .post:
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")
      if params != nil {
        request.httpBody = try? JSONEncoder().encode(params)
        request.addValue("\(request.httpBody?.count ?? 0)", forHTTPHeaderField: "Content-Length")
      }
    }

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey : "Server error: 0"])
    }

    guard 200...299 ~= httpResponse.statusCode else {
      do {
        let xrpcerror = try self.decoder.decode(xrpcErrorDescription.self, from: data)
        if authorization != nil && retry == true {
          if xrpcerror.error == "ExpiredToken" {
            if await self.refreshSession() {
              return try await self.fetch(
                endpoint: endpoint, httpMethod: httpMethod, authorization: self.user.accessJwt,
                params: params, retry: false)
            }
          }
          if xrpcerror.error == "AuthenticationRequired" {
            DispatchQueue.main.async {
              Auth.shared.needAuthorization = true
            }
          }
        }

        throw xrpcerror
      } catch {
        if error is xrpcErrorDescription {
          throw error
        }
        throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey : "Server error: \(httpResponse.statusCode)"])
      }
    }

    if T.self == Bool.self {
      return true as! T
    }

    return try self.decoder.decode(T.self, from: data)
  }
}

struct AuthData: Codable {
  var accessJwt: String = ""
  var refreshJwt: String = ""
  static func load() -> AuthData? {
    if let userdata = Keychain.get("app.swiftsky.userData"),
      let user = try? JSONDecoder().decode(AuthData.self, from: userdata)
    {
      return user
    }
    return nil
  }
  func save() {
    Task {
      if let userdata = try? JSONEncoder().encode(self) {
        Keychain.set(userdata, "app.swiftsky.userData")
      }
    }
  }
}

class Auth: ObservableObject {
  static let shared = Auth()
  @Published var needAuthorization: Bool = true
  public func signout() {
    GlobalViewModel.shared.profile = nil
    Client.shared.handle = ""
    Client.shared.did = ""
    Client.shared.user = .init()
    self.needAuthorization = true
    Task {
      Keychain.delete("app.swiftsky.userData")
    }
  }
}
