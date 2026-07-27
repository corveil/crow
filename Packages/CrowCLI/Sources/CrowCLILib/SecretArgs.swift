import ArgumentParser
import Foundation

/// Password input for `crow web-password set` (CROW-815).
///
/// There is deliberately no `--password` flag: a plaintext password on the
/// command line lands in shell history and is visible to any local `ps` for the
/// lifetime of the process. The password arrives either from an interactive TTY
/// prompt (echo off, typed twice) or from stdin with `--stdin`.
///
/// The pure parts are split out from the I/O so they can be tested without a
/// terminal — see `SecretArgsTests`.
enum SecretArgs {
    /// Reject a password that would be stored but never usable.
    ///
    /// Only emptiness is checked: the server applies no strength rule either, and
    /// inventing one here would make the CLI reject passwords the web UI accepts.
    static func validatePassword(_ value: String) throws -> String {
        guard !value.isEmpty else {
            throw ValidationError("Password must not be empty.")
        }
        return value
    }

    /// Interpret one line read from stdin as a password.
    ///
    /// The line is used verbatim apart from a trailing `\r` (so a CRLF pipe
    /// doesn't silently append a carriage return to the password) — leading and
    /// trailing spaces are meaningful and are kept.
    static func passwordFromStdin(_ line: String?) throws -> String {
        guard let line else {
            throw ValidationError("No password on stdin.")
        }
        var password = line
        if password.hasSuffix("\r") { password.removeLast() }
        return try validatePassword(password)
    }

    /// Confirm a typed password against its repeat.
    static func confirmPassword(_ first: String, _ second: String) throws -> String {
        guard first == second else {
            throw ValidationError("Passwords do not match.")
        }
        return try validatePassword(first)
    }

    /// Read the password from stdin (`--stdin`) or prompt for it twice on the TTY.
    ///
    /// - Throws: `ValidationError` when stdin is empty, the two entries differ,
    ///   or no TTY is attached and `--stdin` was not passed.
    static func readPassword(useStdin: Bool) throws -> String {
        if useStdin {
            return try passwordFromStdin(readLine(strippingNewline: true))
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw ValidationError(
                "No terminal attached — pipe the password and pass --stdin, e.g. "
                    + "`printf '%s' \"$PW\" | crow web-password set --stdin`.")
        }
        let first = try promptSecret("New web password: ")
        let second = try promptSecret("Confirm password: ")
        return try confirmPassword(first, second)
    }

    /// Prompt on the terminal with echo disabled.
    private static func promptSecret(_ prompt: String) throws -> String {
        guard let raw = getpass(prompt) else {
            throw ValidationError("Could not read the password from the terminal.")
        }
        return String(cString: raw)
    }
}
