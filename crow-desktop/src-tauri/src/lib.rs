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

/// Native menu: a Crow app menu, standard Edit (so copy/paste shortcuts work in
/// the web UI), a View menu with Reload (handy for a web frontend), and Window.
fn build_menu(app: &tauri::App) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let about = AboutMetadataBuilder::new().name(Some("Crow")).build();
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
            if port_open() {
                eprintln!("[crow-desktop] crowd already listening on {PORT}; reusing it");
            } else {
                let bin = crowd_bin();
                let mut cmd = Command::new(&bin);
                cmd.arg("--host")
                    .arg("127.0.0.1")
                    .arg("--http-port")
                    .arg(PORT.to_string());
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
