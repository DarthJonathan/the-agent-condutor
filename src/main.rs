#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod app;
mod bridge;
mod claude_config;
mod conversation;
#[cfg(unix)]
mod host;
mod inbox;
mod model;
mod model_catalog;
mod providers;
mod questions;
#[cfg(unix)]
mod remote;
mod runner;
mod storage;
mod team;
mod workspace;

use std::path::PathBuf;

fn main() -> eframe::Result {
    let mut data_dir = None;
    let mut demo = false;
    let mut capture = None;
    let mut initial_view = app::View::Dashboard;
    let mut bridge_mode = false;
    let mut connect_mode = false;
    let mut daemon_mode = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => {
                let Some(path) = args.next() else {
                    eprintln!("--data-dir requires a path");
                    std::process::exit(2);
                };
                data_dir = Some(PathBuf::from(path));
            }
            "--demo" => demo = true,
            "--bridge" => bridge_mode = true,
            "--connect" => connect_mode = true,
            "--daemon" => daemon_mode = true,
            "--supervise" => {}
            "--capture" => {
                let Some(path) = args.next() else {
                    eprintln!("--capture requires a PNG path");
                    std::process::exit(2);
                };
                capture = Some(PathBuf::from(path));
            }
            "--view" => {
                initial_view = match args.next().as_deref() {
                    Some("workspace") => app::View::Dashboard,
                    Some("history") => app::View::History,
                    Some("connections") => app::View::Connections,
                    _ => {
                        eprintln!("--view requires workspace, history, or connections");
                        std::process::exit(2);
                    }
                };
            }
            "--help" | "-h" => {
                println!(
                    "Agent Conductor\n\nUsage: agent-conductor [--data-dir PATH] [--demo] [--capture PNG] [--view workspace|history|connections]\n\n--bridge runs the local JSON engine on stdio.\n--connect attaches stdio to the shared background engine (macOS/Linux).\n--daemon runs the background engine; --supervise waits for an existing host to exit.\n--demo shows sample runs in memory without invoking agents or saving state.\n--capture saves the app's rendered viewport to a PNG, then closes."
                );
                return Ok(());
            }
            _ => {
                eprintln!("Unknown option: {arg}");
                std::process::exit(2);
            }
        }
    }
    if connect_mode || daemon_mode {
        #[cfg(unix)]
        let result = if daemon_mode {
            host::run(data_dir)
        } else {
            host::connect(data_dir)
        };
        #[cfg(not(unix))]
        let result: anyhow::Result<()> = Err(anyhow::anyhow!(
            "Background remote hosting currently requires macOS or Linux"
        ));
        if let Err(error) = result {
            eprintln!("Background engine stopped: {error:#}");
            std::process::exit(1);
        }
        return Ok(());
    }
    if bridge_mode {
        if let Err(error) = bridge::run(data_dir, demo) {
            eprintln!("Agent engine stopped: {error:#}");
            std::process::exit(1);
        }
        return Ok(());
    }
    let viewport = eframe::egui::ViewportBuilder::default()
        .with_title("Agent Conductor")
        .with_inner_size([1320.0, 900.0])
        .with_min_inner_size([1050.0, 740.0]);
    #[cfg(target_os = "macos")]
    let viewport = viewport
        .with_fullsize_content_view(true)
        .with_title_shown(false)
        .with_titlebar_shown(false)
        .with_titlebar_buttons_shown(true);
    let options = eframe::NativeOptions {
        viewport,
        ..Default::default()
    };
    eframe::run_native(
        "Agent Conductor",
        options,
        Box::new(move |cc| {
            Ok(Box::new(app::ConductorApp::new(
                cc,
                data_dir,
                demo,
                capture,
                initial_view,
            )))
        }),
    )
}
