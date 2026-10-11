use crate::{
    model::{
        Availability, DeepSeekMode, LogKind, Provider, Run, Settings, Status, Workflow, clip,
        demo_runs,
    },
    runner::{self, Emitter, Message},
    storage::Store,
};
use chrono::Local;
use eframe::egui::{
    self, Align, Color32, FontId, Frame, Layout, Margin, RichText, Stroke, Vec2, pos2, vec2,
};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{runtime::Runtime, sync::mpsc};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const BG: Color32 = Color32::from_rgb(21, 21, 24);
const SIDEBAR: Color32 = Color32::from_rgb(16, 16, 19);
const PANEL: Color32 = Color32::from_rgb(28, 28, 32);
const INPUT: Color32 = Color32::from_rgb(23, 23, 27);
const BORDER: Color32 = Color32::from_rgb(47, 47, 53);
const TEXT: Color32 = Color32::from_rgb(239, 239, 242);
const MUTED: Color32 = Color32::from_rgb(149, 149, 161);
const ACCENT: Color32 = Color32::from_rgb(127, 160, 245);
const GREEN: Color32 = Color32::from_rgb(102, 196, 153);
const RED: Color32 = Color32::from_rgb(232, 119, 130);
const AMBER: Color32 = Color32::from_rgb(217, 178, 111);

#[derive(Clone, Copy, PartialEq)]
pub enum View {
    Dashboard,
    History,
    Connections,
}
#[derive(Clone, Copy, PartialEq)]
enum DetailTab {
    Response,
    Timeline,
}
enum Action {
    Cancel(Uuid),
    Export(Uuid),
    Copy(String),
    Reuse(Uuid),
}

pub struct ConductorApp {
    runtime: Runtime,
    emitter: Emitter,
    receiver: mpsc::Receiver<Message>,
    store: Store,
    settings: Settings,
    agents: HashMap<Provider, Availability>,
    runs: Vec<Run>,
    active: HashMap<Uuid, CancellationToken>,
    generation: u64,
    view: View,
    prompt: String,
    session_key: String,
    history_search: String,
    selected_run: Option<Uuid>,
    selected_stage: HashMap<Uuid, Provider>,
    detail_tab: DetailTab,
    toast: Option<(String, bool, Instant)>,
    dirty: bool,
    last_save: Instant,
    persistence_blocked: bool,
    demo: bool,
    focus_prompt: bool,
    capture: Option<PathBuf>,
    capture_started: Instant,
    capture_requested: bool,
    workspace_editing: bool,
    composer_expanded: bool,
}

impl ConductorApp {
    pub fn new(
        cc: &eframe::CreationContext<'_>,
        data_dir: Option<PathBuf>,
        demo: bool,
        capture: Option<PathBuf>,
        initial_view: View,
    ) -> Self {
        configure_style(&cc.egui_ctx);
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("Could not start the agent runtime");
        let (sender, receiver) = mpsc::channel(1024);
        let ctx = cc.egui_ctx.clone();
        let emitter = Emitter {
            turn: None,
            sender,
            wake: Arc::new(move || ctx.request_repaint()),
        };
        let store = Store::new(data_dir);
        let mut errors = vec![];
        let mut settings = if demo {
            Settings::default()
        } else {
            store.load_settings().unwrap_or_else(|error| {
                errors.push(format!("{error:#}"));
                Settings::default()
            })
        };
        if !demo
            && !store.root.join("settings.json").exists()
            && runner::existing_deepseek_cli_config(&settings)
        {
            settings.deepseek_use_cli_config = true;
            if let Some(config) = settings
                .agents
                .iter_mut()
                .find(|a| a.provider == Provider::DeepSeek)
            {
                config.model.clear();
            }
        }
        let runs = if demo {
            demo_runs(&settings)
        } else {
            store.load_runs().unwrap_or_else(|error| {
                errors.push(format!("{error:#}"));
                vec![]
            })
        };
        let mut app = Self {
            runtime,
            emitter,
            receiver,
            store,
            settings,
            agents: HashMap::new(),
            runs,
            active: HashMap::new(),
            generation: 0,
            view: initial_view,
            prompt: String::new(),
            session_key: String::new(),
            history_search: String::new(),
            selected_run: None,
            selected_stage: HashMap::new(),
            detail_tab: DetailTab::Response,
            toast: if errors.is_empty() {
                None
            } else {
                Some((errors.join("\n"), true, Instant::now()))
            },
            dirty: false,
            last_save: Instant::now(),
            persistence_blocked: !errors.is_empty(),
            demo,
            focus_prompt: false,
            capture,
            capture_started: Instant::now(),
            capture_requested: false,
            workspace_editing: false,
            composer_expanded: true,
        };
        if demo {
            for provider in Provider::ALL {
                app.agents.insert(
                    provider,
                    Availability::Ready {
                        executable: None,
                        detail: "Sample connection · no agent will be invoked in demo mode".into(),
                    },
                );
            }
            app.settings.agents.iter_mut().for_each(|a| {
                a.selected = matches!(
                    a.provider,
                    Provider::Claude | Provider::Codex | Provider::Qoder
                )
            });
        } else {
            app.rescan();
        }
        app
    }

    fn rescan(&mut self) {
        if self.demo {
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        for provider in Provider::ALL {
            self.agents.insert(provider, Availability::Checking);
        }
        let settings = self.settings.clone();
        let has_key = !self.session_key.trim().is_empty();
        let emitter = self.emitter.clone();
        self.runtime.spawn(async move {
            let agents = runner::discover(settings, has_key, false).await;
            emitter
                .send(Message::Discovery { generation, agents })
                .await;
        });
    }

    fn start_run(&mut self) {
        if self.demo || !self.active.is_empty() {
            return;
        }
        match runner::prepare(
            &self.settings,
            &self.agents,
            &self.prompt,
            &self.session_key,
        ) {
            Ok((run, plan)) => {
                let id = run.id;
                let token = CancellationToken::new();
                self.active.insert(id, token.clone());
                self.runs.insert(0, run);
                self.runs.truncate(100);
                self.selected_run = Some(id);
                self.view = View::Dashboard;
                self.detail_tab = DetailTab::Response;
                self.composer_expanded = false;
                self.dirty = true;
                let emitter = self.emitter.clone();
                self.runtime.spawn(runner::execute(plan, emitter, token));
            }
            Err(error) => self.notify(format!("{error:#}"), true),
        }
    }

    fn receive(&mut self) {
        for _ in 0..1000 {
            let Ok(message) = self.receiver.try_recv() else {
                break;
            };
            match message {
                Message::Discovery { generation, agents } if generation == self.generation => {
                    self.agents = agents
                }
                Message::Discovery { .. } => {}
                Message::Stage {
                    run_id,
                    provider,
                    event,
                } => {
                    let Some(run) = self.runs.iter_mut().find(|r| r.id == run_id) else {
                        continue;
                    };
                    crate::bridge::apply_stage(run, provider, event);
                    if run.status.terminal() {
                        self.active.remove(&run_id);
                    }
                    self.dirty = true;
                }
                Message::ChatAppend { .. }
                | Message::TeamMailbox { .. }
                | Message::TeamQuestion { .. }
                | Message::Changes { .. }
                | Message::CheckFinished { .. }
                | Message::ApprovalResolved { .. }
                | Message::ChatStage { .. }
                | Message::ChatSession { .. }
                | Message::ChatFinished { .. }
                | Message::ChatSuspended { .. } => {}
            }
        }
    }

    fn notify(&mut self, message: String, error: bool) {
        self.toast = Some((message, error, Instant::now()));
    }

    fn save(&mut self) {
        if self.demo || self.persistence_blocked {
            return;
        }
        match self.store.save(&self.settings, &self.runs) {
            Ok(()) => {
                self.dirty = false;
                self.last_save = Instant::now();
            }
            Err(error) => {
                self.last_save = Instant::now();
                self.notify(format!("Could not save dashboard state: {error:#}"), true);
            }
        }
    }

    fn action(&mut self, action: Action, ctx: &egui::Context) {
        match action {
            Action::Cancel(id) => {
                if let Some(token) = self.active.get(&id) {
                    token.cancel();
                }
            }
            Action::Copy(text) => {
                ctx.copy_text(text);
                self.notify("Copied to clipboard".into(), false);
            }
            Action::Export(id) => {
                if self.demo {
                    self.notify("Exports are disabled for sample data.".into(), false);
                    return;
                }
                if let Some(run) = self.runs.iter().find(|r| r.id == id) {
                    match self.store.export(run) {
                        Ok(path) => self.notify(format!("Saved {}", path.display()), false),
                        Err(error) => self.notify(format!("Export failed: {error:#}"), true),
                    }
                }
            }
            Action::Reuse(id) => {
                if let Some(run) = self.runs.iter().find(|r| r.id == id) {
                    self.prompt = run.prompt.clone();
                    self.settings.workspace = run.workspace.clone();
                    self.settings.workflow = run.workflow;
                    for agent in &mut self.settings.agents {
                        agent.selected = run.stages.iter().any(|s| s.provider == agent.provider);
                    }
                    self.dirty = true;
                    self.view = View::Dashboard;
                    self.focus_prompt = true;
                    self.composer_expanded = true;
                }
            }
        }
    }

    fn sidebar(&mut self, ctx: &egui::Context) {
        egui::SidePanel::left("sidebar")
            .exact_width(204.0)
            .resizable(false)
            .frame(
                Frame::new()
                    .fill(SIDEBAR)
                    .inner_margin(Margin::symmetric(16, 20)),
            )
            .show(ctx, |ui| {
                ui.add_space(20.0);
                ui.horizontal(|ui| {
                    brand_mark(ui, 21.0);
                    ui.add_space(3.0);
                    ui.label(strong("Conductor", 16.0).color(TEXT));
                });
                ui.add_space(27.0);
                if ui
                    .add_sized(
                        [ui.available_width(), 35.0],
                        egui::Button::new(strong("+   New task", 12.0))
                            .fill(PANEL)
                            .stroke(Stroke::new(1.0_f32, BORDER))
                            .corner_radius(6),
                    )
                    .clicked()
                {
                    self.view = View::Dashboard;
                    self.prompt.clear();
                    self.focus_prompt = true;
                    self.composer_expanded = true;
                }
                ui.add_space(14.0);
                for (view, label) in [
                    (View::Dashboard, "Workspace"),
                    (View::History, "Run history"),
                    (View::Connections, "Connections"),
                ] {
                    let selected = self.view == view;
                    let color = if selected { TEXT } else { MUTED };
                    let response = ui.add_sized(
                        [ui.available_width(), 36.0],
                        egui::Button::new("")
                            .fill(if selected {
                                Color32::from_rgb(35, 35, 40)
                            } else {
                                Color32::TRANSPARENT
                            })
                            .stroke(Stroke::NONE)
                            .corner_radius(6),
                    );
                    response.widget_info(|| {
                        egui::WidgetInfo::selected(
                            egui::WidgetType::SelectableLabel,
                            true,
                            selected,
                            label,
                        )
                    });
                    nav_icon(
                        ui.painter(),
                        response.rect.left_center() + vec2(16.0, 0.0),
                        view,
                        color,
                    );
                    ui.painter().text(
                        response.rect.left_center() + vec2(34.0, 0.0),
                        egui::Align2::LEFT_CENTER,
                        label,
                        FontId::proportional(13.0),
                        color,
                    );
                    if response.clicked() {
                        self.view = view;
                    }
                    ui.add_space(3.0);
                }
                ui.add_space(28.0);
                ui.label(strong("Recent tasks", 11.0).color(MUTED));
                ui.add_space(10.0);
                if self.runs.is_empty() {
                    ui.label(
                        RichText::new("No tasks yet")
                            .size(12.0)
                            .color(MUTED.gamma_multiply(0.7)),
                    );
                }
                for run in self.runs.iter().take(5) {
                    ui.horizontal(|ui| {
                        dot(ui, status_color(run.status));
                        if ui
                            .add(
                                egui::Button::new(
                                    RichText::new(clip(&run.title(), 24))
                                        .size(12.0)
                                        .color(MUTED),
                                )
                                .frame(false),
                            )
                            .clicked()
                        {
                            self.selected_run = Some(run.id);
                            self.view = View::History;
                        }
                    });
                    ui.add_space(4.0);
                }
                ui.with_layout(Layout::bottom_up(Align::LEFT), |ui| {
                    ui.add_space(3.0);
                    ui.horizontal(|ui| {
                        dot(ui, GREEN);
                        ui.label(RichText::new("Local workspace").size(11.0).color(MUTED));
                    });
                    ui.add_space(14.0);
                    let path = PathBuf::from(&self.settings.workspace);
                    let name = path
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or("Workspace");
                    ui.label(RichText::new(clip(name, 26)).size(12.0).color(TEXT))
                        .on_hover_text(&self.settings.workspace);
                    let count = self
                        .runs
                        .iter()
                        .filter(|r| r.status == Status::Completed)
                        .count();
                    ui.label(
                        RichText::new(format!("{count} completed tasks"))
                            .size(11.0)
                            .color(MUTED),
                    );
                    ui.add_space(12.0);
                    ui.separator();
                });
            });
    }

    fn topbar(&self, ctx: &egui::Context) {
        egui::TopBottomPanel::top("topbar")
            .exact_height(48.0)
            .frame(
                Frame::new()
                    .fill(BG)
                    .inner_margin(Margin::symmetric(28, 12)),
            )
            .show(ctx, |ui| {
                let drag = ui.interact(
                    ui.max_rect(),
                    ui.id().with("window-drag"),
                    egui::Sense::click_and_drag(),
                );
                if drag.drag_started_by(egui::PointerButton::Primary) {
                    ctx.send_viewport_cmd(egui::ViewportCommand::StartDrag);
                }
                if drag.double_clicked() {
                    let maximized = ctx.input(|input| input.viewport().maximized.unwrap_or(false));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Maximized(!maximized));
                }
                ui.horizontal(|ui| {
                    let path = PathBuf::from(&self.settings.workspace);
                    let workspace = path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("Workspace");
                    ui.label(RichText::new(clip(workspace, 40)).size(12.0).color(TEXT));
                    ui.label(RichText::new("/").size(12.0).color(BORDER));
                    ui.label(
                        RichText::new(match self.view {
                            View::Dashboard => "Overview",
                            View::History => "Run history",
                            View::Connections => "Connections",
                        })
                        .size(12.0)
                        .color(MUTED),
                    );
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if self.demo {
                            badge(ui, "SAMPLE DATA · DEMO", AMBER);
                        } else {
                            ui.label(
                                RichText::new(if self.active.is_empty() {
                                    "Idle"
                                } else {
                                    "Agents working"
                                })
                                .size(11.0)
                                .color(MUTED),
                            );
                            dot(
                                ui,
                                if self.active.is_empty() {
                                    MUTED
                                } else {
                                    ACCENT
                                },
                            );
                        }
                    });
                });
                let rect = ui.max_rect();
                ui.painter().hline(
                    rect.x_range(),
                    rect.bottom() + 11.0,
                    Stroke::new(1.0_f32, BORDER.gamma_multiply(0.6)),
                );
            });
    }

    fn dashboard(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.vertical(|ui| {
                ui.label(strong("Workspace", 27.0).color(TEXT));
                ui.add_space(3.0);
                ui.label(
                    RichText::new("A place to think, build, and work with your agents.")
                        .size(13.0)
                        .color(MUTED),
                );
            });
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if secondary(ui, "+  New task").clicked() {
                    self.prompt.clear();
                    self.focus_prompt = true;
                    self.composer_expanded = true;
                }
            });
        });
        ui.add_space(26.0);
        let team_width = 270.0;
        let left_width = (ui.available_width() - team_width - 24.0).max(380.0);
        ui.spacing_mut().item_spacing.x = 24.0;
        ui.horizontal_top(|ui| {
            ui.vertical(|ui| {
                ui.set_width(left_width);
                ui.spacing_mut().item_spacing = vec2(9.0, 8.0);
                self.task_composer(ui);
                ui.add_space(24.0);
                ui.horizontal(|ui| {
                    ui.label(strong("Activity", 14.0).color(TEXT));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui
                            .add(
                                egui::Button::new(
                                    RichText::new("View all").size(12.0).color(MUTED),
                                )
                                .frame(false),
                            )
                            .clicked()
                        {
                            self.view = View::History;
                        }
                    });
                });
                ui.add_space(5.0);
                let chosen = self
                    .selected_run
                    .and_then(|id| self.runs.iter().position(|r| r.id == id))
                    .or_else(|| (!self.runs.is_empty()).then_some(0));
                if let Some(index) = chosen {
                    let run = &self.runs[index];
                    let stage = self.selected_stage.entry(run.id).or_insert(
                        run.stages
                            .first()
                            .map(|s| s.provider)
                            .unwrap_or(Provider::Claude),
                    );
                    let action = render_run(
                        ui,
                        run,
                        stage,
                        &mut self.detail_tab,
                        self.active
                            .get(&run.id)
                            .is_some_and(CancellationToken::is_cancelled),
                    );
                    if let Some(action) = action {
                        self.action(action, ui.ctx());
                    }
                } else {
                    empty_activity(ui);
                }
            });
            ui.vertical(|ui| {
                ui.set_width(team_width);
                ui.spacing_mut().item_spacing = vec2(8.0, 7.0);
                self.team_panel(ui);
            });
        });
    }

    fn task_composer(&mut self, ui: &mut egui::Ui) {
        let mut launch = false;
        card().inner_margin(Margin::same(22)).show(ui, |ui| {
            ui.set_min_width(ui.available_width());
            ui.horizontal(|ui| {
                ui.label(strong(if self.composer_expanded { "New task" } else { "Current task" }, 15.0).color(TEXT));
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if !self.composer_expanded && ui.add(egui::Button::new(RichText::new("Edit task").size(12.0).color(MUTED)).frame(false)).clicked() {
                        self.composer_expanded = true;
                        self.focus_prompt = true;
                    }
                });
            });
            ui.add_space(8.0);
            if self.composer_expanded {
                let response = ui.add_sized([ui.available_width(), 156.0], egui::TextEdit::multiline(&mut self.prompt)
                    .hint_text("Describe the task you want your agents to tackle…")
                    .font(FontId::proportional(16.0)).desired_rows(7).frame(false).margin(vec2(0.0, 7.0)));
                if self.focus_prompt { response.request_focus(); self.focus_prompt = false; }
                ui.add_space(5.0);
                ui.horizontal_wrapped(|ui| {
                    for (label, prompt) in [
                        ("Review code", "Review this workspace. Identify the most important bugs and risks, with file references and suggested fixes."),
                        ("Plan a change", "Inspect this workspace and propose a concrete implementation plan for the following change: "),
                        ("Find a bug", "Inspect this workspace for a reproducible bug. Explain its trigger and propose a focused fix."),
                    ] {
                        if ui.add(egui::Button::new(RichText::new(label).size(11.0).color(MUTED)).fill(INPUT).stroke(Stroke::new(1.0_f32, BORDER)).corner_radius(5)).clicked() {
                            self.prompt = prompt.into();
                            self.focus_prompt = true;
                        }
                    }
                });
            } else {
                ui.label(RichText::new(clip(&self.prompt, 300)).size(14.0).color(TEXT));
            }
            ui.add_space(13.0);
            ui.separator();
            ui.add_space(10.0);
            if self.workspace_editing {
                ui.horizontal(|ui| {
                    let response = ui.add_sized([(ui.available_width() - 52.0).max(200.0), 30.0], egui::TextEdit::singleline(&mut self.settings.workspace).font(FontId::monospace(11.0)).hint_text("/path/to/your/project"));
                    if response.changed() { self.dirty = true; }
                    if ui.small_button("Done").clicked() || response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) { self.workspace_editing = false; }
                });
                ui.add_space(5.0);
            }
            ui.horizontal(|ui| {
                let path = PathBuf::from(&self.settings.workspace);
                let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("Choose workspace");
                if ui.add(egui::Button::new(RichText::new(format!("▱  {}  ⌄", clip(name, 27))).size(12.0).color(MUTED)).frame(false)).on_hover_text(&self.settings.workspace).clicked() {
                    self.workspace_editing = !self.workspace_editing;
                }
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let selected = self.settings.agents.iter().filter(|a| a.selected).collect::<Vec<_>>();
                    let all_ready = selected.iter().all(|a| self.agents.get(&a.provider).is_some_and(Availability::ready));
                    let can_run = !self.demo && self.active.is_empty() && !selected.is_empty() && all_ready && !self.prompt.trim().is_empty();
                    let label = if self.demo { "Demo mode" } else if !self.active.is_empty() { "Working…" } else { "Run agents  ↗" };
                    launch = ui.add_enabled(can_run, egui::Button::new(strong(label, 12.0).color(if can_run { BG } else { MUTED }))
                        .fill(if can_run { ACCENT } else { Color32::from_rgb(43, 43, 49) }).stroke(Stroke::NONE).corner_radius(6).min_size(vec2(130.0, 36.0)))
                        .on_hover_text(if self.demo { "Sample data — no agents will be invoked" } else if !self.active.is_empty() { "Wait for this run to finish, or cancel it below" } else if selected.is_empty() { "Select an agent in Your team" } else if !all_ready { "A selected agent needs setup in Connections" } else { "Start the task with your selected agents" }).clicked();
                    if ui.available_width() > 75.0 {
                        ui.label(RichText::new(if cfg!(target_os = "macos") { "⌘ Enter" } else { "Ctrl Enter" }).size(10.0).color(MUTED));
                    }
                });
            });
        });
        if launch {
            self.start_run();
        }
    }

    fn team_panel(&mut self, ui: &mut egui::Ui) {
        let mut needs_setup = false;
        card().inner_margin(Margin::same(18)).show(ui, |ui| {
            ui.set_min_width(ui.available_width());
            ui.horizontal(|ui| {
                ui.label(strong("Your team", 14.0).color(TEXT));
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let count = self.settings.agents.iter().filter(|a| a.selected).count();
                    ui.label(
                        RichText::new(format!("{count} selected"))
                            .size(11.0)
                            .color(MUTED),
                    );
                });
            });
            ui.add_space(12.0);
            for config in &mut self.settings.agents {
                let availability = self
                    .agents
                    .get(&config.provider)
                    .unwrap_or(&Availability::Checking);
                let response = ui.add_sized(
                    [ui.available_width(), 53.0],
                    egui::Button::new("")
                        .fill(if config.selected {
                            Color32::from_rgb(35, 35, 41)
                        } else {
                            Color32::TRANSPARENT
                        })
                        .stroke(Stroke::NONE)
                        .corner_radius(6),
                );
                response.widget_info(|| {
                    egui::WidgetInfo::selected(
                        egui::WidgetType::Checkbox,
                        availability.ready(),
                        config.selected,
                        config.provider.name(),
                    )
                });
                let painter = ui.painter();
                let center = response.rect.left_center() + vec2(22.0, 0.0);
                painter.rect_filled(
                    egui::Rect::from_center_size(center, Vec2::splat(29.0)),
                    7,
                    provider_color(config.provider).gamma_multiply(0.13),
                );
                painter.text(
                    center,
                    egui::Align2::CENTER_CENTER,
                    match config.provider {
                        Provider::Claude => "✳",
                        Provider::Codex => ">_",
                        Provider::Antigravity => "A",
                        Provider::Qoder => "Q",
                        Provider::DeepSeek => "D",
                        Provider::Kiro => "K",
                    },
                    FontId::proportional(14.0),
                    provider_color(config.provider),
                );
                painter.text(
                    response.rect.left_top() + vec2(45.0, 11.0),
                    egui::Align2::LEFT_TOP,
                    config.provider.name(),
                    FontId::new(13.0, egui::FontFamily::Name("interface-strong".into())),
                    TEXT,
                );
                painter.text(
                    response.rect.left_top() + vec2(45.0, 30.0),
                    egui::Align2::LEFT_TOP,
                    availability.label(),
                    FontId::proportional(11.0),
                    if availability.ready() || matches!(availability, Availability::Checking) {
                        MUTED
                    } else {
                        AMBER
                    },
                );
                let check = egui::Rect::from_center_size(
                    response.rect.right_center() - vec2(16.0, 0.0),
                    Vec2::splat(14.0),
                );
                painter.rect_filled(check, 4, if config.selected { ACCENT } else { INPUT });
                if config.selected {
                    painter.line_segment(
                        [
                            check.center() + vec2(-3.5, 0.0),
                            check.center() + vec2(-0.7, 2.5),
                        ],
                        Stroke::new(1.6_f32, BG),
                    );
                    painter.line_segment(
                        [
                            check.center() + vec2(-0.7, 2.5),
                            check.center() + vec2(4.0, -3.0),
                        ],
                        Stroke::new(1.6_f32, BG),
                    );
                } else {
                    painter.rect_stroke(
                        check,
                        4,
                        Stroke::new(1.0_f32, BORDER),
                        egui::StrokeKind::Inside,
                    );
                }
                if response.on_hover_text(availability.detail()).clicked() {
                    if availability.ready() {
                        config.selected = !config.selected;
                        self.dirty = true;
                    } else if !matches!(availability, Availability::Checking) {
                        needs_setup = true;
                    }
                }
                ui.add_space(2.0);
            }
            ui.add_space(13.0);
            ui.separator();
            ui.add_space(11.0);
            ui.label(strong("Workflow", 11.0).color(MUTED));
            ui.add_space(3.0);
            ui.horizontal(|ui| {
                for (workflow, label) in [
                    (Workflow::Independent, "Parallel"),
                    (Workflow::Collaborate, "Handoff"),
                ] {
                    if ui
                        .selectable_value(
                            &mut self.settings.workflow,
                            workflow,
                            RichText::new(label).size(12.0),
                        )
                        .changed()
                    {
                        self.dirty = true;
                    }
                }
            });
            ui.add_space(6.0);
            ui.label(
                RichText::new(match self.settings.workflow {
                    Workflow::Independent => "Each agent tackles the same task in its own session.",
                    Workflow::Conversation => "Persistent Chat is available in the native macOS app. Choose Parallel or Handoff here.",
                    Workflow::Collaborate => {
                        "Agents take turns, passing their findings to the next."
                    }
                })
                .size(11.0)
                .color(MUTED),
            );
            if self.settings.workflow == Workflow::Collaborate {
                let team = self
                    .settings
                    .agents
                    .iter()
                    .filter(|a| a.selected)
                    .map(|a| a.provider.name())
                    .collect::<Vec<_>>()
                    .join(" → ");
                ui.label(RichText::new(team).size(11.0).color(ACCENT));
            }
            ui.add_space(10.0);
            if ui
                .add(
                    egui::Button::new(
                        RichText::new("Manage connections  ↗")
                            .size(11.0)
                            .color(MUTED),
                    )
                    .frame(false),
                )
                .clicked()
            {
                needs_setup = true;
            }
        });
        if needs_setup {
            self.view = View::Connections;
        }
    }

    fn history(&mut self, ui: &mut egui::Ui) {
        page_heading(
            ui,
            "Run history",
            "Every task, response, and handoff. Saved on this computer.",
        );
        ui.add_space(22.0);
        ui.horizontal(|ui| {
            ui.add_sized(
                [340.0, 33.0],
                egui::TextEdit::singleline(&mut self.history_search)
                    .hint_text("Search tasks or agents…"),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.label(
                    RichText::new(format!("{} saved tasks", self.runs.len()))
                        .size(11.0)
                        .color(MUTED),
                );
            });
        });
        ui.add_space(17.0);
        if self.runs.is_empty() {
            empty_activity(ui);
            return;
        }
        let search = self.history_search.to_lowercase();
        egui::ScrollArea::vertical()
            .id_salt("history-list")
            .max_height(245.0)
            .show(ui, |ui| {
                let mut count = 0;
                for run in &self.runs {
                    let provider_names = run
                        .stages
                        .iter()
                        .map(|s| s.provider.name())
                        .collect::<Vec<_>>()
                        .join(", ");
                    if !search.is_empty()
                        && !run.prompt.to_lowercase().contains(&search)
                        && !provider_names.to_lowercase().contains(&search)
                    {
                        continue;
                    }
                    count += 1;
                    let selected = self.selected_run == Some(run.id);
                    let response = Frame::new()
                        .fill(if selected {
                            Color32::from_rgb(35, 38, 46)
                        } else {
                            PANEL
                        })
                        .stroke(Stroke::new(
                            1.0_f32,
                            if selected {
                                ACCENT.gamma_multiply(0.5)
                            } else {
                                BORDER
                            },
                        ))
                        .corner_radius(7)
                        .inner_margin(Margin::symmetric(16, 12))
                        .show(ui, |ui| {
                            ui.set_min_width(ui.available_width());
                            ui.horizontal(|ui| {
                                dot(ui, status_color(run.status));
                                ui.vertical(|ui| {
                                    ui.label(RichText::new(run.title()).size(13.0).strong());
                                    ui.label(
                                        RichText::new(format!(
                                            "{} · {} · {}",
                                            run.created_at
                                                .with_timezone(&Local)
                                                .format("%b %d, %H:%M"),
                                            run.workflow.name(),
                                            provider_names
                                        ))
                                        .size(10.5)
                                        .color(MUTED),
                                    );
                                });
                                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                    badge(ui, run.status.name(), status_color(run.status));
                                });
                            });
                        })
                        .response;
                    if ui
                        .interact(response.rect, ui.id().with(run.id), egui::Sense::click())
                        .clicked()
                    {
                        self.selected_run = Some(run.id);
                    }
                    ui.add_space(7.0);
                }
                if count == 0 {
                    ui.label(RichText::new("No tasks match this search.").color(MUTED));
                }
            });
        ui.add_space(23.0);
        let index = self
            .selected_run
            .and_then(|id| self.runs.iter().position(|r| r.id == id))
            .unwrap_or(0);
        let run = &self.runs[index];
        let stage = self.selected_stage.entry(run.id).or_insert(
            run.stages
                .first()
                .map(|s| s.provider)
                .unwrap_or(Provider::Claude),
        );
        let action = render_run(
            ui,
            run,
            stage,
            &mut self.detail_tab,
            self.active
                .get(&run.id)
                .is_some_and(CancellationToken::is_cancelled),
        );
        if let Some(action) = action {
            self.action(action, ui.ctx());
        }
    }

    fn connections(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            page_heading(
                ui,
                "Bring your own agents.",
                "Connect local CLIs. Run DeepSeek through Claude Code or its streaming API.",
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if secondary(ui, "Save & check").clicked() {
                    self.dirty = true;
                    self.save();
                    self.rescan();
                }
            });
        });
        ui.add_space(21.0);
        let mut moved = None;
        for (index, config) in self.settings.agents.iter_mut().enumerate() {
            let availability = self
                .agents
                .get(&config.provider)
                .unwrap_or(&Availability::Checking)
                .clone();
            ui.push_id(config.provider, |ui| {
                card().inner_margin(Margin::same(19)).show(ui, |ui| {
                    ui.set_min_width(ui.available_width());
                    ui.horizontal(|ui| {
                        provider_mark(ui, config.provider, 33.0);
                        ui.vertical(|ui| {
                            ui.label(RichText::new(config.provider.name()).size(17.0).strong());
                            ui.label(RichText::new(config.provider.tagline()).size(10.5).color(MUTED));
                        });
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if ui.add_enabled(index < 4, egui::Button::new("Later").frame(false)).on_hover_text("Move later in the collaboration").clicked() { moved = Some((index, index + 1)); }
                            if ui.add_enabled(index > 0, egui::Button::new("Earlier").frame(false)).on_hover_text("Move earlier in the collaboration").clicked() { moved = Some((index, index - 1)); }
                            badge(ui, availability.label(), if availability.ready() { GREEN } else { AMBER });
                        });
                    });
                    ui.add_space(13.0);
                    ui.label(RichText::new(availability.detail()).size(11.5).color(MUTED));
                    ui.add_space(12.0);
                    if config.provider == Provider::DeepSeek {
                        ui.horizontal(|ui| {
                            for (mode, label) in [(DeepSeekMode::ClaudeCode, "Claude Code · agent"), (DeepSeekMode::DirectApi, "Direct API · text")] {
                                if ui.selectable_value(&mut self.settings.deepseek_mode, mode, label).changed() { self.dirty = true; self.agents.insert(Provider::DeepSeek, Availability::Checking); }
                            }
                        });
                        ui.add_space(8.0);
                        if self.settings.deepseek_mode == DeepSeekMode::ClaudeCode {
                            if ui.checkbox(&mut self.settings.deepseek_use_cli_config, "Use Claude Code's existing DeepSeek provider configuration").changed() {
                                self.dirty = true; self.agents.insert(Provider::DeepSeek, Availability::Checking);
                            }
                            ui.add_space(8.0);
                        }
                        ui.columns(2, |cols| {
                            field_label(&mut cols[0], "SESSION API KEY");
                            cols[0].add_enabled_ui(self.settings.deepseek_mode == DeepSeekMode::DirectApi || !self.settings.deepseek_use_cli_config, |ui| {
                                if ui.add_sized([ui.available_width(), 31.0], egui::TextEdit::singleline(&mut self.session_key).password(true).hint_text("Or use DEEPSEEK_API_KEY")).changed() { self.agents.insert(Provider::DeepSeek, Availability::Checking); }
                            });
                            field_label(&mut cols[1], "MODEL");
                            if cols[1].add_sized([cols[1].available_width(), 31.0], egui::TextEdit::singleline(&mut config.model).hint_text(if self.settings.deepseek_use_cli_config && self.settings.deepseek_mode == DeepSeekMode::ClaudeCode { "Use the CLI's configured model" } else { "deepseek-flash" })).changed() { self.dirty = true; }
                        });
                        ui.add_space(9.0);
                        field_label(ui, "API BASE URL");
                        if ui.add_sized([ui.available_width(), 31.0], egui::TextEdit::singleline(&mut self.settings.deepseek_base_url)).changed() { self.dirty = true; }
                        ui.add_space(7.0);
                        ui.label(RichText::new("The session key stays in memory. It is never saved in settings, history, or exports.").size(10.5).color(MUTED));
                        if self.settings.deepseek_mode == DeepSeekMode::ClaudeCode {
                            ui.add_space(10.0);
                            field_label(ui, "CLAUDE CODE EXECUTABLE");
                            if ui.add_sized([ui.available_width(), 31.0], egui::TextEdit::singleline(&mut config.executable).hint_text("Auto-detect claude")).changed() { self.dirty = true; self.agents.insert(Provider::DeepSeek, Availability::Checking); }
                            if ui.checkbox(&mut config.allow_edits, "Approve workspace file edits for this agent").changed() { self.dirty = true; }
                            ui.label(RichText::new("The headless harness provides workspace tools. Claude Code's permission rules still apply.").size(10.5).color(MUTED));
                            ui.collapsing("Additional CLI arguments", |ui| {
                                if ui.add_sized([ui.available_width(), 31.0], egui::TextEdit::singleline(&mut config.extra_args).font(FontId::monospace(11.0))).changed() { self.dirty = true; }
                            });
                        } else {
                            ui.label(RichText::new("The direct API receives text only and has no workspace tools.").size(10.5).color(MUTED));
                        }
                    } else {
                        ui.columns(2, |cols| {
                            field_label(&mut cols[0], "EXECUTABLE");
                            if cols[0].add_sized([cols[0].available_width(), 31.0], egui::TextEdit::singleline(&mut config.executable).hint_text(format!("Auto-detect {}", config.provider.executable_names().join(" / ")))).changed() {
                                self.agents.insert(config.provider, Availability::Checking);
                                self.dirty = true;
                            }
                            field_label(&mut cols[1], "MODEL");
                            if cols[1].add_sized([cols[1].available_width(), 31.0], egui::TextEdit::singleline(&mut config.model).hint_text("Use the CLI's configured model")).changed() { self.dirty = true; }
                        });
                        ui.add_space(10.0);
                        if config.provider != Provider::Antigravity {
                            if ui.checkbox(&mut config.allow_edits, "Approve workspace file edits for this agent").changed() { self.dirty = true; }
                            ui.label(RichText::new(if config.provider == Provider::Codex {
                                "Uses the read-only sandbox unless file edits are enabled. Approval prompts are denied."
                            } else { "Uses the CLI's permission rules. Enabling file edits selects its accept-edits mode. Other approval prompts are denied." }).size(10.5).color(MUTED));
                        } else {
                            ui.label(RichText::new("Uses Antigravity's own permission settings, which can allow workspace writes.").size(10.5).color(MUTED));
                        }
                        ui.add_space(6.0);
                        ui.collapsing(RichText::new("Additional CLI arguments").size(11.0).color(MUTED), |ui| {
                            ui.label(RichText::new("Enter an argv array, for example [\"--effort\", \"high\"]. These values are passed directly to the CLI.").size(10.5).color(MUTED));
                            if ui.add_sized([ui.available_width(), 31.0], egui::TextEdit::singleline(&mut config.extra_args).font(FontId::monospace(11.0))).changed() { self.dirty = true; }
                            if serde_json::from_str::<Vec<String>>(&config.extra_args).is_err() { ui.colored_label(RED, "Expected a JSON array of strings."); }
                        });
                    }
                    ui.add_space(9.0);
                    ui.hyperlink_to(RichText::new("Setup & headless documentation").size(11.0).color(ACCENT), config.provider.docs_url());
                });
            });
            ui.add_space(13.0);
        }
        if let Some((from, to)) = moved {
            self.settings.agents.swap(from, to);
            self.dirty = true;
        }
        ui.add_space(8.0);
        card().inner_margin(Margin::same(19)).show(ui, |ui| {
            ui.label(RichText::new("Run settings").size(16.0).strong());
            ui.add_space(12.0);
            ui.horizontal(|ui| {
                ui.label(RichText::new("Timeout per agent").size(12.0).color(MUTED));
                if ui.add(egui::DragValue::new(&mut self.settings.timeout_seconds).range(10..=7200).suffix(" sec").speed(30)).changed() { self.dirty = true; }
            });
            ui.add_space(10.0);
            ui.label(RichText::new(format!("Local data: {}", self.store.root.display())).size(10.5).color(MUTED));
            ui.label(RichText::new("History retains up to 100 tasks. Independent agents share the workspace; use collaboration for ordered edits.").size(10.5).color(MUTED));
        });
    }
    fn capture_viewport(&mut self, ctx: &egui::Context) {
        let Some(path) = self.capture.as_ref() else {
            return;
        };
        let screenshot = ctx.input(|input| {
            input.events.iter().find_map(|event| match event {
                egui::Event::Screenshot { image, .. } => Some(image.clone()),
                _ => None,
            })
        });
        if let Some(screenshot) = screenshot {
            let save = || -> anyhow::Result<()> {
                if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                    std::fs::create_dir_all(parent)?;
                }
                let pixels: Vec<u8> = screenshot
                    .pixels
                    .iter()
                    .flat_map(|pixel| pixel.to_srgba_unmultiplied())
                    .collect();
                image::save_buffer_with_format(
                    path,
                    &pixels,
                    screenshot.size[0] as u32,
                    screenshot.size[1] as u32,
                    image::ColorType::Rgba8,
                    image::ImageFormat::Png,
                )?;
                Ok(())
            };
            match save() {
                Ok(()) => eprintln!("Saved dashboard capture: {}", path.display()),
                Err(error) => eprintln!("Could not save dashboard capture: {error:#}"),
            }
            self.capture = None;
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        } else if self.capture_started.elapsed() > Duration::from_secs(15) {
            eprintln!("Dashboard capture timed out before the renderer returned an image");
            self.capture = None;
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        } else {
            let checking = self
                .agents
                .values()
                .any(|agent| matches!(agent, Availability::Checking));
            if !self.capture_requested
                && self.capture_started.elapsed() > Duration::from_millis(500)
                && (!checking || self.capture_started.elapsed() > Duration::from_secs(10))
            {
                self.capture_requested = true;
                ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(Default::default()));
            }
            ctx.request_repaint_after(Duration::from_millis(50));
        }
    }
}

impl eframe::App for ConductorApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.receive();
        if self.dirty && self.last_save.elapsed() > Duration::from_secs(2) {
            self.save();
        }
        if !self.active.is_empty()
            || self
                .agents
                .values()
                .any(|a| matches!(a, Availability::Checking))
        {
            ctx.request_repaint_after(Duration::from_millis(100));
        }
        if self.view == View::Dashboard
            && ctx.input_mut(|i| i.consume_key(egui::Modifiers::COMMAND, egui::Key::Enter))
        {
            self.start_run();
        }
        self.sidebar(ctx);
        self.topbar(ctx);
        if let Some((message, error, started)) = &self.toast
            && (started.elapsed() < Duration::from_secs(12) || self.persistence_blocked)
        {
            let mut dismiss = false;
            egui::TopBottomPanel::bottom("notice")
                .frame(
                    Frame::new()
                        .fill(if *error {
                            Color32::from_rgb(54, 28, 36)
                        } else {
                            Color32::from_rgb(25, 43, 37)
                        })
                        .inner_margin(Margin::symmetric(26, 12)),
                )
                .show(ctx, |ui| {
                    ui.horizontal(|ui| {
                        ui.add(
                            egui::Label::new(RichText::new(message).size(11.0).color(if *error {
                                RED
                            } else {
                                GREEN
                            }))
                            .wrap(),
                        );
                        if !self.persistence_blocked {
                            dismiss = ui.small_button("×").clicked();
                        }
                    });
                });
            if dismiss {
                self.toast = None;
            }
            ctx.request_repaint_after(Duration::from_secs(1));
        }
        egui::CentralPanel::default()
            .frame(Frame::new().fill(BG).inner_margin(Margin::same(28)))
            .show(ctx, |ui| {
                egui::ScrollArea::vertical()
                    .id_salt("main-scroll")
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        match self.view {
                            View::Dashboard => self.dashboard(ui),
                            View::History => self.history(ui),
                            View::Connections => self.connections(ui),
                        }
                        ui.add_space(22.0);
                    });
            });
        self.capture_viewport(ctx);
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        for token in self.active.values() {
            token.cancel();
        }
        self.save();
    }
}

impl Drop for ConductorApp {
    fn drop(&mut self) {
        for token in self.active.values() {
            token.cancel();
        }
    }
}

fn configure_style(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    #[cfg(target_os = "macos")]
    {
        if let Ok(bytes) = std::fs::read("/System/Library/Fonts/SFNS.ttf") {
            fonts.font_data.insert(
                "interface".into(),
                Arc::new(egui::FontData::from_owned(bytes)),
            );
            fonts
                .families
                .entry(egui::FontFamily::Proportional)
                .or_default()
                .insert(0, "interface".into());
        }
        if let Ok(bytes) = std::fs::read("/System/Library/Fonts/Supplemental/Arial Bold.ttf") {
            fonts.font_data.insert(
                "interface-strong".into(),
                Arc::new(egui::FontData::from_owned(bytes)),
            );
        }
    }
    let mut strong = fonts.families[&egui::FontFamily::Proportional].clone();
    if fonts.font_data.contains_key("interface-strong") {
        strong.insert(0, "interface-strong".into());
    }
    fonts
        .families
        .insert(egui::FontFamily::Name("interface-strong".into()), strong);
    ctx.set_fonts(fonts);
    let mut style = (*ctx.style()).clone();
    style.visuals = egui::Visuals::dark();
    style.visuals.override_text_color = Some(TEXT);
    style.visuals.panel_fill = BG;
    style.visuals.window_fill = PANEL;
    style.visuals.extreme_bg_color = INPUT;
    style.visuals.faint_bg_color = PANEL;
    style.visuals.selection.bg_fill = Color32::from_rgb(45, 57, 80);
    style.visuals.selection.stroke = Stroke::new(1.0_f32, ACCENT);
    style.visuals.hyperlink_color = ACCENT;
    style.visuals.widgets.noninteractive.bg_stroke = Stroke::new(1.0_f32, BORDER);
    style.visuals.widgets.inactive.bg_fill = INPUT;
    style.visuals.widgets.inactive.weak_bg_fill = PANEL;
    style.visuals.widgets.inactive.bg_stroke = Stroke::new(1.0_f32, BORDER);
    style.visuals.widgets.hovered.bg_fill = Color32::from_rgb(42, 42, 48);
    style.visuals.widgets.hovered.weak_bg_fill = Color32::from_rgb(42, 42, 48);
    style.visuals.widgets.hovered.bg_stroke = Stroke::new(1.0_f32, ACCENT.gamma_multiply(0.5));
    style.visuals.widgets.active.bg_fill = Color32::from_rgb(45, 57, 80);
    style.visuals.widgets.active.weak_bg_fill = Color32::from_rgb(45, 57, 80);
    style.spacing.item_spacing = vec2(9.0, 6.0);
    style.spacing.button_padding = vec2(12.0, 7.0);
    style.spacing.interact_size = vec2(30.0, 30.0);
    style.spacing.scroll = egui::style::ScrollStyle::solid();
    style
        .text_styles
        .insert(egui::TextStyle::Body, FontId::proportional(14.0));
    style
        .text_styles
        .insert(egui::TextStyle::Button, FontId::proportional(13.0));
    ctx.set_style(style);
}

fn strong(text: impl Into<String>, size: f32) -> RichText {
    RichText::new(text).font(FontId::new(
        size,
        egui::FontFamily::Name("interface-strong".into()),
    ))
}

fn card() -> Frame {
    Frame::new()
        .fill(PANEL)
        .stroke(Stroke::new(1.0_f32, BORDER))
        .corner_radius(9)
}

fn page_heading(ui: &mut egui::Ui, title: &str, subtitle: &str) {
    ui.vertical(|ui| {
        ui.label(strong(title, 27.0));
        ui.add_space(5.0);
        ui.label(RichText::new(subtitle).size(12.5).color(MUTED));
    });
}

fn field_label(ui: &mut egui::Ui, label: &str) {
    ui.label(
        RichText::new(label)
            .size(9.5)
            .extra_letter_spacing(0.7)
            .color(MUTED),
    );
}

fn secondary(ui: &mut egui::Ui, label: &str) -> egui::Response {
    ui.add(
        egui::Button::new(RichText::new(label).size(11.5).color(TEXT))
            .fill(PANEL)
            .stroke(Stroke::new(1.0_f32, BORDER))
            .corner_radius(6)
            .min_size(vec2(100.0, 34.0)),
    )
}

fn dot(ui: &mut egui::Ui, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(vec2(7.0, 10.0), egui::Sense::hover());
    ui.painter().circle_filled(rect.center(), 2.5, color);
}

fn badge(ui: &mut egui::Ui, text: &str, color: Color32) {
    Frame::new()
        .fill(color.gamma_multiply(0.12))
        .corner_radius(4)
        .inner_margin(Margin::symmetric(8, 4))
        .show(ui, |ui| {
            ui.label(RichText::new(text).size(9.5).color(color));
        });
}

fn brand_mark(ui: &mut egui::Ui, size: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(size), egui::Sense::hover());
    let heights = [0.35, 0.7, 1.0, 0.55];
    for (i, height) in heights.into_iter().enumerate() {
        let x = rect.left() + i as f32 * size * 0.235;
        let h = size * height;
        ui.painter().rect_filled(
            egui::Rect::from_min_size(pos2(x, rect.center().y - h / 2.0), vec2(size * 0.13, h)),
            2,
            ACCENT,
        );
    }
}

fn nav_icon(painter: &egui::Painter, center: egui::Pos2, view: View, color: Color32) {
    let stroke = Stroke::new(1.2_f32, color);
    match view {
        View::Dashboard => {
            for offset in [
                vec2(-4.0, -4.0),
                vec2(4.0, -4.0),
                vec2(-4.0, 4.0),
                vec2(4.0, 4.0),
            ] {
                painter.rect_stroke(
                    egui::Rect::from_center_size(center + offset, Vec2::splat(5.0)),
                    1,
                    stroke,
                    egui::StrokeKind::Inside,
                );
            }
        }
        View::History => {
            painter.circle_stroke(center, 7.0, stroke);
            painter.line_segment([center + vec2(0.0, -4.0), center], stroke);
            painter.line_segment([center, center + vec2(3.5, 2.0)], stroke);
        }
        View::Connections => {
            let nodes = [
                center + vec2(0.0, -5.0),
                center + vec2(-5.0, 4.0),
                center + vec2(5.0, 4.0),
            ];
            painter.line_segment([nodes[0], nodes[1]], stroke);
            painter.line_segment([nodes[0], nodes[2]], stroke);
            for node in nodes {
                painter.circle_filled(node, 2.5, SIDEBAR);
                painter.circle_stroke(node, 2.5, stroke);
            }
        }
    }
}

fn provider_color(provider: Provider) -> Color32 {
    match provider {
        Provider::Claude => Color32::from_rgb(222, 161, 122),
        Provider::Codex => Color32::from_rgb(142, 212, 186),
        Provider::Antigravity => Color32::from_rgb(136, 180, 249),
        Provider::Qoder => Color32::from_rgb(186, 162, 251),
        Provider::DeepSeek => Color32::from_rgb(131, 171, 255),
        Provider::Kiro => Color32::from_rgb(181, 143, 242),
    }
}

fn provider_mark(ui: &mut egui::Ui, provider: Provider, size: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(size), egui::Sense::hover());
    let color = provider_color(provider);
    ui.painter()
        .rect_filled(rect, 7, color.gamma_multiply(0.12));
    let mark = match provider {
        Provider::Claude => "C",
        Provider::Codex => ">_",
        Provider::Antigravity => "A",
        Provider::Qoder => "Q",
        Provider::DeepSeek => "D",
        Provider::Kiro => "K",
    };
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        mark,
        FontId::monospace(size * 0.45),
        color,
    );
}

fn status_color(status: Status) -> Color32 {
    match status {
        Status::Completed => GREEN,
        Status::Running => ACCENT,
        Status::Failed => RED,
        Status::WaitingForUser => AMBER,
        Status::Queued | Status::Cancelled | Status::Interrupted => MUTED,
    }
}

fn compact_number(value: u64) -> String {
    if value >= 1_000_000 {
        format!("{:.1}m", value as f64 / 1_000_000.0)
    } else if value >= 1000 {
        format!("{:.1}k", value as f64 / 1000.0)
    } else {
        value.to_string()
    }
}

fn empty_activity(ui: &mut egui::Ui) {
    card().inner_margin(Margin::same(25)).show(ui, |ui| {
        ui.set_min_width(ui.available_width());
        ui.vertical_centered(|ui| {
            ui.add_space(6.0);
            let (rect, _) = ui.allocate_exact_size(vec2(32.0, 30.0), egui::Sense::hover());
            let terminal = rect.shrink(2.0);
            ui.painter().rect_stroke(
                terminal,
                6,
                Stroke::new(1.0_f32, MUTED.gamma_multiply(0.6)),
                egui::StrokeKind::Inside,
            );
            let center = terminal.center();
            ui.painter().line_segment(
                [center + vec2(-7.0, -4.0), center + vec2(-3.0, 0.0)],
                Stroke::new(1.3_f32, MUTED),
            );
            ui.painter().line_segment(
                [center + vec2(-3.0, 0.0), center + vec2(-7.0, 4.0)],
                Stroke::new(1.3_f32, MUTED),
            );
            ui.painter().line_segment(
                [center + vec2(1.0, 4.0), center + vec2(7.0, 4.0)],
                Stroke::new(1.3_f32, MUTED),
            );
            ui.add_space(9.0);
            ui.label(strong("No runs yet", 14.0).color(TEXT));
            ui.label(
                RichText::new("Your agents’ results will appear here.")
                    .size(12.0)
                    .color(MUTED),
            );
            ui.add_space(6.0);
        });
    });
}

fn render_run(
    ui: &mut egui::Ui,
    run: &Run,
    selected: &mut Provider,
    tab: &mut DetailTab,
    cancelling: bool,
) -> Option<Action> {
    let mut action = None;
    card().inner_margin(Margin::same(19)).show(ui, |ui| {
        ui.set_min_width(ui.available_width());
        ui.horizontal(|ui| {
            dot(ui, status_color(run.status));
            ui.label(strong(run.status.name(), 12.0).color(status_color(run.status)));
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if !run.status.terminal() {
                    if ui
                        .add_enabled(
                            !cancelling,
                            egui::Button::new(
                                RichText::new(if cancelling {
                                    "Cancelling…"
                                } else {
                                    "Cancel run"
                                })
                                .size(11.0)
                                .color(RED),
                            ),
                        )
                        .clicked()
                    {
                        action = Some(Action::Cancel(run.id));
                    }
                } else if ui.small_button("Use task again").clicked() {
                    action = Some(Action::Reuse(run.id));
                }
            });
        });
        ui.add_space(6.0);
        ui.label(strong(run.title(), 15.0));
        ui.add_space(3.0);
        ui.label(
            RichText::new(format!(
                "{} · {} · {}s",
                run.workflow.name(),
                run.created_at.with_timezone(&Local).format("%H:%M"),
                run.elapsed_seconds()
            ))
            .size(10.5)
            .color(MUTED),
        );
        ui.add_space(14.0);
        ui.horizontal_wrapped(|ui| {
            for stage in &run.stages {
                let text = RichText::new(format!(
                    "{}  ·  {}",
                    stage.provider.name(),
                    stage.status.name()
                ))
                .size(11.5)
                .color(if *selected == stage.provider {
                    provider_color(stage.provider)
                } else {
                    MUTED
                });
                ui.selectable_value(selected, stage.provider, text);
            }
        });
        ui.add_space(10.0);
        ui.separator();
        let Some(stage) = run
            .stages
            .iter()
            .find(|s| s.provider == *selected)
            .or_else(|| run.stages.first())
        else {
            return;
        };
        ui.horizontal(|ui| {
            ui.selectable_value(
                tab,
                DetailTab::Response,
                RichText::new("Response").size(11.0),
            );
            ui.selectable_value(
                tab,
                DetailTab::Timeline,
                RichText::new(format!("Timeline ({})", stage.logs.len())).size(11.0),
            );
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if ui
                    .add(
                        egui::Button::new(RichText::new("Export").size(10.5).color(MUTED))
                            .frame(false),
                    )
                    .clicked()
                {
                    action = Some(Action::Export(run.id));
                }
                if ui
                    .add_enabled(
                        !stage.output.is_empty(),
                        egui::Button::new(RichText::new("Copy").size(10.5).color(MUTED))
                            .frame(false),
                    )
                    .clicked()
                {
                    action = Some(Action::Copy(stage.output.clone()));
                }
            });
        });
        ui.add_space(10.0);
        egui::ScrollArea::vertical()
            .id_salt((
                "run-detail",
                run.id,
                stage.provider,
                *tab == DetailTab::Timeline,
            ))
            .max_height(340.0)
            .auto_shrink([false, false])
            .stick_to_bottom(!run.status.terminal())
            .show(ui, |ui| {
                ui.set_min_height(110.0);
                match tab {
                    DetailTab::Response => {
                        if let Some(error) = &stage.error {
                            Frame::new()
                                .fill(Color32::from_rgb(47, 28, 35))
                                .corner_radius(5)
                                .inner_margin(Margin::same(12))
                                .show(ui, |ui| {
                                    ui.add(
                                        egui::Label::new(
                                            RichText::new(error).size(12.0).color(RED),
                                        )
                                        .wrap(),
                                    );
                                });
                            ui.add_space(8.0);
                        }
                        if !stage.output.is_empty() {
                            render_markdown(ui, &stage.output);
                        } else {
                            ui.add_space(18.0);
                            ui.horizontal(|ui| {
                                if stage.status == Status::Running {
                                    ui.spinner();
                                }
                                ui.label(
                                    RichText::new(match stage.status {
                                        Status::Queued => "Waiting for this agent's turn…",
                                        Status::WaitingForUser => {
                                            "Waiting for your answer in the native chat."
                                        }
                                        Status::Running => {
                                            "Waiting for the agent's first response…"
                                        }
                                        Status::Completed => {
                                            "This agent returned no response text."
                                        }
                                        Status::Failed => {
                                            "Open Timeline for the agent's diagnostics."
                                        }
                                        Status::Cancelled => "This stage was cancelled.",
                                        Status::Interrupted => {
                                            "This stage was interrupted when the app closed."
                                        }
                                    })
                                    .size(12.0)
                                    .color(MUTED),
                                );
                            });
                        }
                    }
                    DetailTab::Timeline => {
                        if stage.logs.is_empty() {
                            ui.label(
                                RichText::new("Events will appear when the agent starts.")
                                    .color(MUTED),
                            );
                        }
                        for entry in &stage.logs {
                            ui.horizontal_top(|ui| {
                                ui.label(
                                    RichText::new(
                                        entry
                                            .at
                                            .with_timezone(&Local)
                                            .format("%H:%M:%S")
                                            .to_string(),
                                    )
                                    .monospace()
                                    .size(10.0)
                                    .color(MUTED),
                                );
                                dot(
                                    ui,
                                    match entry.kind {
                                        LogKind::Info => MUTED,
                                        LogKind::Tool => ACCENT,
                                        LogKind::Warning => AMBER,
                                        LogKind::Error => RED,
                                    },
                                );
                                ui.add(
                                    egui::Label::new(RichText::new(&entry.text).size(11.0).color(
                                        if entry.kind == LogKind::Error {
                                            RED
                                        } else {
                                            TEXT
                                        },
                                    ))
                                    .wrap(),
                                );
                            });
                            ui.add_space(5.0);
                        }
                    }
                }
            });
        ui.add_space(10.0);
        ui.separator();
        ui.horizontal(|ui| {
            let tokens = stage.usage.input_tokens + stage.usage.output_tokens;
            ui.label(
                RichText::new(if tokens == 0 {
                    "Token usage pending or unreported".into()
                } else {
                    format!(
                        "{} in · {} out",
                        compact_number(stage.usage.input_tokens),
                        compact_number(stage.usage.output_tokens)
                    )
                })
                .size(10.0)
                .color(MUTED),
            );
            if let Some(cost) = stage.usage.cost_usd {
                ui.label(RichText::new(format!("${cost:.4}")).size(10.0).color(MUTED));
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if let Some(id) = &stage.session_id {
                    ui.label(
                        RichText::new(format!("Session {}", clip(id, 15)))
                            .monospace()
                            .size(9.5)
                            .color(MUTED),
                    )
                    .on_hover_text(id);
                }
            });
        });
    });
    action
}

/// A small, non-executing Markdown view. Full source remains available via Copy/Export.
fn render_markdown(ui: &mut egui::Ui, text: &str) {
    let mut code = false;
    let mut block = String::new();
    for line in text.lines() {
        if line.trim_start().starts_with("```") {
            if code {
                Frame::new()
                    .fill(INPUT)
                    .corner_radius(5)
                    .inner_margin(Margin::same(12))
                    .show(ui, |ui| {
                        ui.add(
                            egui::Label::new(
                                RichText::new(&block)
                                    .monospace()
                                    .size(11.5)
                                    .color(Color32::from_rgb(191, 205, 225)),
                            )
                            .wrap(),
                        );
                    });
                block.clear();
                ui.add_space(7.0);
            }
            code = !code;
        } else if code {
            block.push_str(line);
            block.push('\n');
        } else if line.trim().is_empty() {
            ui.add_space(7.0);
        } else if let Some(title) = line
            .strip_prefix("### ")
            .or_else(|| line.strip_prefix("## "))
            .or_else(|| line.strip_prefix("# "))
        {
            ui.add_space(5.0);
            ui.label(RichText::new(title).size(15.0).strong());
        } else {
            ui.add(egui::Label::new(RichText::new(line).size(12.5).color(TEXT)).wrap());
        }
    }
    if !block.is_empty() {
        ui.add(egui::Label::new(RichText::new(block).monospace().size(11.5)).wrap());
    }
}
