import AppKit
import Foundation

enum ExitStatus: Int32 {
  case success = 0
  case usage = 2
  case absent = 3
  case mismatch = 4
  case rejectedOrTimedOut = 5
}

enum Action: String {
  case status
  case graceful
  case force
  case terminate
}

struct ExpectedIdentity {
  let bundleIdentifier: String
  let bundlePath: String
  let executablePath: String
  let processIdentifier: pid_t
}

@inline(__always)
private func fail(_ status: ExitStatus, _ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(status.rawValue)
}

private func canonicalPath(_ path: String) -> String {
  URL(fileURLWithPath: path)
    .resolvingSymlinksInPath()
    .standardizedFileURL
    .path
}

private func runningApplications(for identity: ExpectedIdentity) -> [NSRunningApplication] {
  NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleIdentifier)
    .filter { !$0.isTerminated }
}

private func exactApplication(for identity: ExpectedIdentity) -> NSRunningApplication {
  let applications = runningApplications(for: identity)
  guard !applications.isEmpty else {
    fail(.absent, "isolated identity is not running: \(identity.bundleIdentifier)")
  }
  guard applications.count == 1, let application = applications.first else {
    let pids = applications.map { String($0.processIdentifier) }.joined(separator: ",")
    fail(
      .mismatch,
      "isolated identity is ambiguous: \(identity.bundleIdentifier) pids=[\(pids)]"
    )
  }
  guard application.processIdentifier == identity.processIdentifier else {
    fail(
      .mismatch,
      "isolated identity changed pid: expected=\(identity.processIdentifier) observed=\(application.processIdentifier)"
    )
  }
  guard let bundleURL = application.bundleURL,
    canonicalPath(bundleURL.path) == canonicalPath(identity.bundlePath)
  else {
    fail(.mismatch, "isolated identity is running from an unexpected bundle path")
  }
  guard let executableURL = application.executableURL,
    canonicalPath(executableURL.path) == canonicalPath(identity.executablePath)
  else {
    fail(.mismatch, "isolated identity is running from an unexpected executable path")
  }
  return application
}

private func waitForExactExit(
  _ application: NSRunningApplication,
  identity: ExpectedIdentity,
  timeout: TimeInterval
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    let applications = runningApplications(for: identity)
    if applications.isEmpty {
      return true
    }
    guard applications.count == 1, let current = applications.first else {
      let pids = applications.map { String($0.processIdentifier) }.joined(separator: ",")
      fail(
        .mismatch,
        "isolated identity became ambiguous while exiting: pids=[\(pids)]"
      )
    }
    guard current.processIdentifier == application.processIdentifier,
      current.processIdentifier == identity.processIdentifier
    else {
      fail(
        .mismatch,
        "isolated identity relaunched or changed pid while exiting: expected=\(identity.processIdentifier) observed=\(current.processIdentifier)"
      )
    }
    guard let bundleURL = current.bundleURL,
      canonicalPath(bundleURL.path) == canonicalPath(identity.bundlePath),
      let executableURL = current.executableURL,
      canonicalPath(executableURL.path) == canonicalPath(identity.executablePath)
    else {
      fail(.mismatch, "isolated identity changed bundle or executable while exiting")
    }
    if Date() >= deadline {
      return false
    }
    Thread.sleep(forTimeInterval: 0.05)
  } while true
}

private func requireExactExit(
  _ application: NSRunningApplication,
  identity: ExpectedIdentity,
  timeout: TimeInterval
) {
  guard waitForExactExit(application, identity: identity, timeout: timeout) else {
    fail(
      .rejectedOrTimedOut,
      "isolated identity did not exit within \(timeout) seconds: pid=\(identity.processIdentifier)"
    )
  }
}

private func requestGracefulExit(
  _ application: NSRunningApplication,
  identity: ExpectedIdentity,
  timeout: TimeInterval
) -> Bool {
  if application.terminate() {
    return waitForExactExit(application, identity: identity, timeout: timeout)
  }

  // A false return can race a process which has already exited. Re-read the
  // exact identity before deciding whether the retained application remains a
  // valid force-termination target.
  return waitForExactExit(application, identity: identity, timeout: 0)
}

private func requestForceExit(
  _ application: NSRunningApplication,
  identity: ExpectedIdentity,
  timeout: TimeInterval
) {
  guard application.forceTerminate() else {
    if waitForExactExit(application, identity: identity, timeout: 0) {
      return
    }
    fail(
      .rejectedOrTimedOut,
      "NSRunningApplication rejected force termination for pid=\(identity.processIdentifier)"
    )
  }
  requireExactExit(application, identity: identity, timeout: timeout)
}

private let arguments = CommandLine.arguments
guard arguments.count == 7 else {
  fail(
    .usage,
    "usage: isolated-app-control.swift <status|graceful|force|terminate> <bundle-id> <bundle-path> <executable-path> <expected-pid> <timeout-seconds>"
  )
}
guard let action = Action(rawValue: arguments[1]) else {
  fail(.usage, "unknown isolated-app control action: \(arguments[1])")
}
let bundleIdentifier = arguments[2]
if bundleIdentifier == "io.vetcoders.pensieve" {
  fail(.mismatch, "refusing production Pensieve bundle identifier")
}
let ownedIdentityPattern =
  #"^io\.vetcoders\.pensieve\.(manual|smoke|memory|bugmap)\.r[0-9a-f]{32}$"#
guard bundleIdentifier.range(of: ownedIdentityPattern, options: .regularExpression) != nil else {
  fail(.mismatch, "refusing non-owned isolated bundle identifier: \(bundleIdentifier)")
}
guard !arguments[2].isEmpty,
  arguments[3].hasPrefix("/"),
  arguments[4].hasPrefix("/"),
  let expectedPID = pid_t(arguments[5]),
  expectedPID > 0,
  let timeout = TimeInterval(arguments[6]),
  timeout >= 0
else {
  fail(.usage, "invalid isolated-app control identity arguments")
}

let identity = ExpectedIdentity(
  bundleIdentifier: bundleIdentifier,
  bundlePath: arguments[3],
  executablePath: arguments[4],
  processIdentifier: expectedPID
)
let application = exactApplication(for: identity)

switch action {
case .status:
  print(application.processIdentifier)
case .graceful:
  guard requestGracefulExit(application, identity: identity, timeout: timeout) else {
    fail(
      .rejectedOrTimedOut,
      "isolated identity did not exit gracefully within \(timeout) seconds: pid=\(expectedPID)"
    )
  }
case .force:
  requestForceExit(application, identity: identity, timeout: timeout)
case .terminate:
  if !requestGracefulExit(application, identity: identity, timeout: timeout) {
    // Keep using the same retained NSRunningApplication. The bounded wait has
    // revalidated PID, bundle id, bundle path, and executable path on every
    // turn; an ambiguity or relaunch exits with status 4 before this call.
    requestForceExit(application, identity: identity, timeout: timeout)
  }
}
