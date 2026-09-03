// Crow desktop shell (Tauri v2).
//
// Spawns the `crowd` daemon as a sidecar on launch, waits for it to listen,
// then points the window at its web UI; kills it on exit. If a crowd is already
// listening on PORT (e.g. one started manually), it is reused instead of
// spawning a second — a second crowd on the same devRoot would contend on the
// shared store.json + tmux cockpit.
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};
use tauri::menu::{AboutMetadataBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::Manager;

/// Port the sidecar crowd binds. Honors CROW_HTTP_PORT (matching
/// scripts/daemon-run.sh) so launching the app beside a custom-port crowd reuses
/// it instead of spawning a second daemon on 8787 against the same devRoot
/// (review #11).
fn port() -> u16 {
    std::env::var("CROW_HTTP_PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(8787)
}

/// Holds the spawned crowd child so we can kill it when the app exits.
struct Crowd(Mutex<Option<Child>>);

/// Path to the crowd binary.
///
/// `CROWD_BIN` always wins. Debug builds keep the SwiftPM output at
/// `<repo>/.build/debug/crowd` (same as `make run`). Release builds look next to
/// this executable for a Tauri sidecar: `crowd-<target-triple>` (what
/// `bundle.externalBin` installs into `Contents/MacOS`), then unsuffixed
/// `crowd` (what `tauri-build` copies next to an unbundled `target/release/Crow`).
fn crowd_bin() -> PathBuf {
    resolve_crowd_bin(
        std::env::var_os("CROWD_BIN").map(PathBuf::from),
        cfg!(debug_assertions),
        std::env::current_exe().ok(),
        env!("TAURI_ENV_TARGET_TRIPLE"),
        Path::new(env!("CARGO_MANIFEST_DIR")),
    )
}

/// Pure resolver so release/debug/sidecar layout can be unit-tested without
/// spawning the window. `debug` is passed in rather than read from
/// `cfg!(debug_assertions)` so the release branch is reachable from debug tests.
fn resolve_crowd_bin(
    override_bin: Option<PathBuf>,
    debug: bool,
    current_exe: Option<PathBuf>,
    target_triple: &str,
    manifest_dir: &Path,
) -> PathBuf {
    if let Some(p) = override_bin {
        if !p.as_os_str().is_empty() {
            return p;
        }
    }
    if debug {
        return manifest_dir.join("../../.build/debug/crowd");
    }
    let dir = current_exe
        .as_deref()
        .and_then(Path::parent)
        .unwrap_or_else(|| Path::new("."));
    let suffixed = dir.join(format!("crowd-{target_triple}"));
    if suffixed.exists() {
        return suffixed;
    }
    dir.join("crowd")
}

/// Whether something is accepting TCP connections on 127.0.0.1:PORT.
fn port_open() -> bool {
    match ("127.0.0.1", port()).to_socket_addrs().ok().and_then(|mut a| a.next()) {
        Some(addr) => TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok(),
        None => false,
    }
}

/// Whether the listener on 127.0.0.1:`port` is actually crowd — verified by the
/// `Server: crowd` response header (present on every crowd HTTP response). Guards
/// against pointing the privileged webview (which carries Tauri IPC) at another
/// local process squatting on the port (review #7).
fn is_crowd(port: u16) -> bool {
    use std::io::{Read, Write};
    let addr = match ("127.0.0.1", port).to_socket_addrs().ok().and_then(|mut a| a.next()) {
        Some(a) => a,
        None => return false,
    };
    let mut stream = match TcpStream::connect_timeout(&addr, Duration::from_millis(500)) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(1000)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(1000)));
    let req =
        format!("GET /version.json HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(req.as_bytes()).is_err() {
        return false;
    }
    let mut buf = [0u8; 1024];
    let mut resp = Vec::new();
    while let Ok(n) = stream.read(&mut buf) {
        if n == 0 {
            break;
        }
        resp.extend_from_slice(&buf[..n]);
        if resp.len() >= 4096 {
            break;
        }
    }
    String::from_utf8_lossy(&resp)
        .to_ascii_lowercase()
        .contains("server: crowd")
}

fn wait_for_port(timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if port_open() {
            return true;
        }
        thread::sleep(Duration::from_millis(150));
    }
    false
}

/// Force-enable this app's accessibility so the embedded WKWebView exposes its
/// web-content accessibility tree to the macOS Accessibility (AX) API (CROW-750).
///
/// The web UI runs in a WKWebView, which builds its AX tree out-of-process and
/// only *lazily* — WebKit (like Chromium/Gecko) waits until the host app's
/// `NSApplication.accessibilityEnhancedUserInterface` is set (the flag VoiceOver
/// flips) before it exposes the DOM to the AX API. Safari sets this proactively;
/// a bare wry WKWebView never does. So AX-based dictation tools (Wispr Flow) and
/// other non-VoiceOver assistive clients see *no* focused text field and fall
/// back to "click where to paste" instead of pasting on mic release. In a plain
/// browser the tree is exposed, which is why dictation only breaks in the app.
///
/// We set the flag directly on our own `NSApplication` (the internal AppKit
/// setter — self-targeting needs no accessibility permission). Note: driving the
/// *same* attribute through the AX API against our own pid returns
/// `kAXErrorNotImplemented` (that path is only meant for a second process like
/// VoiceOver), so the direct property setter is the one that actually takes.
///
/// Must run on the main thread (it touches `NSApplication`). Known trade-off:
/// this attribute also nudges some window-manager/zoom behavior once (it
/// disables a couple of window animations) — benign for a single-window app.
#[cfg(target_os = "macos")]
fn enable_webkit_accessibility() {
    use objc2::msg_send;
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSApplication;

    let Some(mtm) = MainThreadMarker::new() else {
        eprintln!("[crow-desktop] a11y enable skipped: not on the main thread");
        return;
    };
    let app = NSApplication::sharedApplication(mtm);
    // Safety: `app` is the live shared NSApplication; the selector takes a BOOL.
    unsafe {
        let _: () = msg_send![&app, setAccessibilityEnhancedUserInterface: true];
        // Opt-in readback for verifying the flag actually took at runtime
        // (`CROW_AX_DEBUG=1`); silent otherwise.
        if std::env::var_os("CROW_AX_DEBUG").is_some() {
            let on: bool = msg_send![&app, isAccessibilityEnhancedUserInterface];
            eprintln!("[crow-desktop][a11y] accessibilityEnhancedUserInterface = {on}");
        }
    }
}

/// No-op on non-macOS: the AX/WKWebView plumbing this addresses is macOS-only.
#[cfg(not(target_os = "macos"))]
fn enable_webkit_accessibility() {}

/// CROW-1030: the commit page for a stamped build SHA on the upstream repo.
/// `None` for anything that would land on a 404 — `dev` (built outside a git
/// checkout), empty, or non-hex — so the menu item disables instead of opening
/// a broken page. Mirrors `crowCommitURL` in the web UI and
/// `VersionUpdateClient.githubCompareURL` in Swift.
fn crow_commit_url(sha: &str) -> Option<String> {
    let s = sha.trim().to_ascii_lowercase();
    if !(7..=40).contains(&s.len()) || !s.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!("https://github.com/corveil/crow/commit/{s}"))
}

/// Native menu: a Crow app menu, standard Edit (so copy/paste shortcuts work in
/// the web UI), a View menu with Reload (handy for a web frontend), and Window.
fn build_menu(app: &tauri::App) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let about = AboutMetadataBuilder::new()
        .name(Some("Crow"))
        .version(Some(format!("0.1.0 · {}", env!("CROW_GIT_SHA"))))
        .icon(app.default_window_icon().cloned())
        .build();
    // macOS draws the About panel itself (NSAboutPanel) and muda hands it plain
    // strings, so the SHA *inside* that panel cannot be made clickable. The
    // control lives beside it instead: same commit, one menu item away, and
    // disabled when the SHA isn't a real commit (CROW-1030).
    let build_link = MenuItemBuilder::with_id("build-on-github", "Build on GitHub")
        .enabled(crow_commit_url(env!("CROW_GIT_SHA_FULL")).is_some())
        .build(app)?;
    let app_menu = SubmenuBuilder::new(app, "Crow")
        .about(Some(about))
        .item(&build_link)
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .quit()
        .build()?;
    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;
    let reload = MenuItemBuilder::with_id("reload", "Reload")
        .accelerator("CmdOrCtrl+R")
        .build(app)?;
    let view_menu = SubmenuBuilder::new(app, "View")
        .item(&reload)
        .separator()
        .fullscreen()
        .build()?;
    let window_menu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .separator()
        .close_window()
        .build()?;
    MenuBuilder::new(app)
        .items(&[&app_menu, &edit_menu, &view_menu, &window_menu])
        .build()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .manage(Crowd(Mutex::new(None)))
        .on_menu_event(|app, event| {
            if event.id().as_ref() == "reload" {
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.eval("window.location.reload()");
                }
            } else if event.id().as_ref() == "build-on-github" {
                // Unreachable while the SHA is unlinkable — the item is built
                // disabled — but re-derived rather than captured so the URL has
                // one source of truth (CROW-1030).
                if let Some(url) = crow_commit_url(env!("CROW_GIT_SHA_FULL")) {
                    if let Err(e) = tauri_plugin_opener::open_url(&url, None::<&str>) {
                        eprintln!("[crow-desktop] open {url} failed: {e}");
                    }
                }
            }
        })
        .setup(|app| {
            let menu = build_menu(app)?;
            app.set_menu(menu)?;

            // Enable accessibility before the real UI loads so the WKWebView's
            // WebContent process inherits the enabled state and exposes its AX
            // tree to dictation/assistive tools (CROW-750). Re-asserted after
            // navigate() below as belt-and-suspenders.
            enable_webkit_accessibility();

            // Reuse an already-running crowd; otherwise spawn our own sidecar.
            // Only reuse a listener that identifies as crowd (review #7).
            if port_open() {
                if is_crowd(port()) {
                    eprintln!("[crow-desktop] crowd already listening on {}; reusing it", port());
                } else {
                    eprintln!(
                        "[crow-desktop] 127.0.0.1:{} is held by a non-crowd process; not spawning a \
                         sidecar and refusing to load until it is free.",
                        port()
                    );
                }
            } else {
                let bin = crowd_bin();
                let mut cmd = Command::new(&bin);
                cmd.arg("--host")
                    .arg("127.0.0.1")
                    .arg("--http-port")
                    .arg(port().to_string());
                // Pass through a custom unix socket so a CROW_SOCKET-configured
                // crowd doesn't contend on the default socket (review #11).
                if let Ok(sock) = std::env::var("CROW_SOCKET") {
                    if !sock.is_empty() {
                        cmd.arg("--socket").arg(sock);
                    }
                }
                // No --web-dir: the sidecar serves the frozen web assets baked
                // into crowd's resource bundle at `make daemon` time, so UI edits
                // don't show until an explicit rebuild. The `make daemon-run`
                // dev loop serves the same frozen assets (no live-from-source).
                match cmd.spawn() {
                    Ok(child) => {
                        eprintln!(
                            "[crow-desktop] spawned crowd ({}) pid {}",
                            bin.display(),
                            child.id()
                        );
                        *app.state::<Crowd>().0.lock().unwrap() = Some(child);
                    }
                    Err(e) => eprintln!(
                        "[crow-desktop] failed to spawn crowd at {}: {e}",
                        bin.display()
                    ),
                }
            }

            // Wait for crowd off the UI thread, then navigate the window to it —
            // but only after confirming the listener is actually crowd, so the
            // privileged webview can't be pointed at a foreign process on the port
            // (review #7).
            let handle = app.handle().clone();
            thread::spawn(move || {
                if !wait_for_port(Duration::from_secs(30)) {
                    eprintln!("[crow-desktop] crowd did not come up on {} within 30s", port());
                    return;
                }
                if !is_crowd(port()) {
                    eprintln!(
                        "[crow-desktop] refusing to navigate: 127.0.0.1:{} did not identify as crowd",
                        port()
                    );
                    return;
                }
                if let Some(win) = handle.get_webview_window("main") {
                    match format!("http://127.0.0.1:{}", port()).parse() {
                        Ok(url) => {
                            let _ = win.navigate(url);
                            // Re-assert accessibility for the freshly navigated
                            // document's WebContent process (CROW-750). The flag
                            // is app-global, but re-setting it is cheap and keeps
                            // the guarantee independent of process (re)spawn order.
                            // We're on a worker thread here; the NSApplication
                            // setter must run on the main thread.
                            let _ = handle.run_on_main_thread(enable_webkit_accessibility);
                        }
                        Err(e) => eprintln!("[crow-desktop] bad crowd url: {e}"),
                    }
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                if let Some(state) = app.try_state::<Crowd>() {
                    if let Some(mut child) = state.0.lock().unwrap().take() {
                        // Graceful shutdown: SIGTERM, wait briefly for crowd to
                        // flush its store / release tmux + socket, then SIGKILL as a
                        // fallback, and reap so no zombie is left (review #12).
                        let pid = child.id();
                        eprintln!("[crow-desktop] stopping crowd pid {pid} (SIGTERM)");
                        unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM); }
                        let deadline = Instant::now() + Duration::from_millis(1500);
                        loop {
                            match child.try_wait() {
                                Ok(Some(_)) => break,
                                Ok(None) if Instant::now() < deadline => {
                                    thread::sleep(Duration::from_millis(50));
                                }
                                _ => {
                                    let _ = child.kill();
                                    break;
                                }
                            }
                        }
                        let _ = child.wait();
                    }
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::{crow_commit_url, resolve_crowd_bin};
    use std::fs;
    use std::path::{Path, PathBuf};

    #[test]
    fn links_a_real_sha() {
        assert_eq!(
            crow_commit_url("2a24aeb3").as_deref(),
            Some("https://github.com/corveil/crow/commit/2a24aeb3")
        );
        // Full 40-char hashes and mixed case both normalize to a lowercase URL.
        let full = "abc1234567890abcdef1234567890abcdef12345";
        assert_eq!(
            crow_commit_url(&full.to_ascii_uppercase()).as_deref(),
            Some(format!("https://github.com/corveil/crow/commit/{full}").as_str())
        );
        assert!(crow_commit_url("  2a24aeb3 \n").is_some(), "trims whitespace");
    }

    #[test]
    fn refuses_anything_that_would_404() {
        for sha in [
            "dev",      // built outside a git checkout
            "",         // never stamped
            "   ",
            "2a24ae",   // 6 chars — below git's minimum unambiguous prefix
            "abc1234567890abcdef1234567890abcdef123456", // 41 chars
            "zzzzzzz",  // non-hex
            "2a24aeb3/../../evil",
        ] {
            assert!(crow_commit_url(sha).is_none(), "expected None for {sha:?}");
        }
    }

    fn scratch_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "crow-desktop-crowd-bin-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn crowd_bin_override_wins_in_debug_and_release() {
        let override_bin = PathBuf::from("/tmp/custom-crowd");
        let manifest = Path::new("/repo/crow-desktop/src-tauri");
        for debug in [true, false] {
            let got = resolve_crowd_bin(
                Some(override_bin.clone()),
                debug,
                Some(PathBuf::from("/Applications/Crow.app/Contents/MacOS/Crow")),
                "aarch64-apple-darwin",
                manifest,
            );
            assert_eq!(got, override_bin, "debug={debug}");
        }
    }

    #[test]
    fn crowd_bin_debug_uses_swiftpm_debug_output() {
        let manifest = Path::new("/repo/crow-desktop/src-tauri");
        let got = resolve_crowd_bin(None, true, None, "aarch64-apple-darwin", manifest);
        assert_eq!(got, PathBuf::from("/repo/crow-desktop/src-tauri/../../.build/debug/crowd"));
    }

    #[test]
    fn crowd_bin_empty_override_falls_through() {
        let manifest = Path::new("/repo/crow-desktop/src-tauri");
        let got = resolve_crowd_bin(
            Some(PathBuf::from("")),
            true,
            None,
            "aarch64-apple-darwin",
            manifest,
        );
        assert_eq!(got, PathBuf::from("/repo/crow-desktop/src-tauri/../../.build/debug/crowd"));
    }

    #[test]
    fn crowd_bin_release_prefers_tauri_sidecar_triple_suffix() {
        let dir = scratch_dir();
        let exe = dir.join("Crow");
        fs::write(&exe, []).unwrap();
        let sidecar = dir.join("crowd-aarch64-apple-darwin");
        fs::write(&sidecar, []).unwrap();
        let unsuffixed = dir.join("crowd");
        fs::write(&unsuffixed, []).unwrap();

        let got = resolve_crowd_bin(
            None,
            false,
            Some(exe),
            "aarch64-apple-darwin",
            Path::new("/unused"),
        );
        assert_eq!(got, sidecar);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn crowd_bin_release_falls_back_to_unsuffixed_next_to_exe() {
        let dir = scratch_dir();
        let exe = dir.join("Crow");
        fs::write(&exe, []).unwrap();
        let unsuffixed = dir.join("crowd");
        fs::write(&unsuffixed, []).unwrap();

        let got = resolve_crowd_bin(
            None,
            false,
            Some(exe),
            "aarch64-apple-darwin",
            Path::new("/unused"),
        );
        assert_eq!(got, unsuffixed);
        let _ = fs::remove_dir_all(&dir);
    }
}
