// Crow desktop shell (Tauri v2).
//
// Spawns the `crowd` daemon as a sidecar on launch, waits for it to listen,
// then points the window at its web UI; kills it on exit. If a crowd is already
// listening on PORT (e.g. one started manually), it is reused instead of
// spawning a second — a second crowd on the same devRoot would contend on the
// shared store.json + tmux cockpit.
use std::net::{TcpStream, ToSocketAddrs};
use std::process::{Child, Command};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};
use tauri::menu::{AboutMetadataBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::Manager;

/// Port the sidecar crowd binds. Honors CROW_HTTP_PORT (matching
/// scripts/crowd-dev.sh) so launching the app beside a custom-port crowd reuses
/// it instead of spawning a second daemon on 8787 against the same devRoot
/// (review #11).
fn port() -> u16 {
    std::env::var("CROW_HTTP_PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(8787)
}

/// Holds the spawned crowd child so we can kill it when the app exits.
struct Crowd(Mutex<Option<Child>>);

/// Path to the crowd binary. Dev: `<repo>/.build/debug/crowd`, resolved relative
/// to this crate. Override with `CROWD_BIN`. A release build will bundle crowd as
/// a proper Tauri sidecar instead (TODO).
fn crowd_bin() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("CROWD_BIN") {
        return p.into();
    }
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.build/debug/crowd")
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

/// Native menu: a Crow app menu, standard Edit (so copy/paste shortcuts work in
/// the web UI), a View menu with Reload (handy for a web frontend), and Window.
fn build_menu(app: &tauri::App) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let about = AboutMetadataBuilder::new()
        .name(Some("Crow"))
        .version(Some(format!("0.1.0 · {}", env!("CROW_GIT_SHA"))))
        .icon(app.default_window_icon().cloned())
        .build();
    let app_menu = SubmenuBuilder::new(app, "Crow")
        .about(Some(about))
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
            }
        })
        .setup(|app| {
            let menu = build_menu(app)?;
            app.set_menu(menu)?;

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
                // Dev: serve web assets live from source so UI edits show on reload
                // (matches `make crowd-dev`). Skipped when the source tree isn't
                // present (e.g. a release install), where crowd uses its bundle.
                let web = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../Packages/CrowDaemon/Sources/CrowDaemon/Resources/web");
                if web.is_dir() {
                    cmd.arg("--web-dir").arg(&web);
                }
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
