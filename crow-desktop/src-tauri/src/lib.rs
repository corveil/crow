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
use tauri::Manager;

/// Port the sidecar crowd binds (matches crowd's default).
const PORT: u16 = 8787;

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
    match ("127.0.0.1", PORT).to_socket_addrs().ok().and_then(|mut a| a.next()) {
        Some(addr) => TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok(),
        None => false,
    }
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(Crowd(Mutex::new(None)))
        .setup(|app| {
            // Reuse an already-running crowd; otherwise spawn our own sidecar.
            if port_open() {
                eprintln!("[crow-desktop] crowd already listening on {PORT}; reusing it");
            } else {
                let bin = crowd_bin();
                match Command::new(&bin)
                    .arg("--host")
                    .arg("127.0.0.1")
                    .arg("--http-port")
                    .arg(PORT.to_string())
                    .spawn()
                {
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

            // Wait for crowd off the UI thread, then navigate the window to it.
            let handle = app.handle().clone();
            thread::spawn(move || {
                if wait_for_port(Duration::from_secs(30)) {
                    if let Some(win) = handle.get_webview_window("main") {
                        match format!("http://127.0.0.1:{PORT}").parse() {
                            Ok(url) => {
                                let _ = win.navigate(url);
                            }
                            Err(e) => eprintln!("[crow-desktop] bad crowd url: {e}"),
                        }
                    }
                } else {
                    eprintln!("[crow-desktop] crowd did not come up on {PORT} within 30s");
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
                        eprintln!("[crow-desktop] killing crowd pid {}", child.id());
                        let _ = child.kill();
                    }
                }
            }
        });
}
