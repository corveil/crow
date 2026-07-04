import CrowDaemon

// Thin entrypoint for the `crowd` daemon. All logic lives in the `CrowDaemon`
// library so it can be unit-tested and reused (CROW-581). A file named
// `main.swift` supports top-level `await`, so no `@main` type is needed.
try await CrowDaemon.run()
