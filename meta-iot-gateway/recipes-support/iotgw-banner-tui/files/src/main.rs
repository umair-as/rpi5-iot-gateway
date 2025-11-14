use anyhow::Result;
use crossterm::{
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style, Stylize},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame, Terminal,
};
use std::io;
use std::fs;
use sysinfo::System;

fn get_distro_name() -> &'static str {
    option_env!("DISTRO_NAME").unwrap_or("IoT Gateway OS")
}

fn get_distro_version() -> &'static str {
    option_env!("DISTRO_VERSION").unwrap_or("1.0.0")
}

fn get_machine() -> &'static str {
    option_env!("MACHINE").unwrap_or("Host Machine")
}

struct SystemInfo {
    hostname: String,
    kernel: String,
    uptime: String,
    ip_addrs: Vec<String>,
    rauc_slot: String,
    cpu_usage: f32,
    memory_used: u64,
    memory_total: u64,
    cpu_temp: Option<f32>,
}

impl SystemInfo {
    fn new() -> Self {
        let mut sys = System::new_all();
        sys.refresh_all();

        let hostname = fs::read_to_string("/etc/hostname")
            .unwrap_or_else(|_| "iot-gateway".to_string())
            .trim()
            .to_string();

        let kernel = System::kernel_version().unwrap_or_else(|| "unknown".to_string());

        let uptime_secs = System::uptime();
        let days = uptime_secs / 86400;
        let hours = (uptime_secs % 86400) / 3600;
        let mins = (uptime_secs % 3600) / 60;
        let uptime = if days > 0 {
            format!("{}d {}h {}m", days, hours, mins)
        } else if hours > 0 {
            format!("{}h {}m", hours, mins)
        } else {
            format!("{}m", mins)
        };

        // Get IP addresses
        let mut ip_addrs = Vec::new();
        if let Ok(output) = std::process::Command::new("hostname").arg("-I").output() {
            if let Ok(ips) = String::from_utf8(output.stdout) {
                for ip in ips.split_whitespace() {
                    if !ip.starts_with("127.") && !ip.starts_with("::") {
                        ip_addrs.push(ip.to_string());
                    }
                }
            }
        }
        if ip_addrs.is_empty() {
            ip_addrs.push("N/A".to_string());
        }

        let rauc_slot = std::process::Command::new("rauc")
            .args(&["status"])
            .output()
            .ok()
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .and_then(|s| {
                s.lines()
                    .find(|l| l.contains("Booted from:"))
                    .map(|l| l.split(':').nth(1).unwrap_or("unknown").trim().to_string())
            })
            .unwrap_or_else(|| "N/A (not installed)".to_string());

        let cpu_usage = sys.global_cpu_info().cpu_usage();
        let memory_used = sys.used_memory();
        let memory_total = sys.total_memory();

        // Try to get CPU temperature (RPi specific)
        let cpu_temp = fs::read_to_string("/sys/class/thermal/thermal_zone0/temp")
            .ok()
            .and_then(|s| s.trim().parse::<f32>().ok())
            .map(|t| t / 1000.0);

        Self {
            hostname,
            kernel,
            uptime,
            ip_addrs,
            rauc_slot,
            cpu_usage,
            memory_used,
            memory_total,
            cpu_temp,
        }
    }
}

fn render_logo(frame: &mut Frame, area: Rect) {
    let logo_lines = vec![
        Line::from(vec![
            Span::styled("    ██╗ ██████╗ ████████╗     ", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
            Span::styled("██████╗  █████╗ ████████╗███████╗██╗    ██╗ █████╗ ██╗   ██╗", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("    ██║██╔═══██╗╚══██╔══╝    ", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
            Span::styled("██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝██║    ██║██╔══██╗╚██╗ ██╔╝", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("    ██║██║   ██║   ██║       ", Style::default().fg(Color::Blue).add_modifier(Modifier::BOLD)),
            Span::styled("██║  ███╗███████║   ██║   █████╗  ██║ █╗ ██║███████║ ╚████╔╝", Style::default().fg(Color::Blue).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("    ██║██║   ██║   ██║       ", Style::default().fg(Color::Blue).add_modifier(Modifier::BOLD)),
            Span::styled("██║   ██║██╔══██║   ██║   ██╔══╝  ██║███╗██║██╔══██║  ╚██╔╝", Style::default().fg(Color::Blue).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("    ██║╚██████╔╝   ██║       ", Style::default().fg(Color::Blue)),
            Span::styled("╚██████╔╝██║  ██║   ██║   ███████╗╚███╔███╔╝██║  ██║   ██║", Style::default().fg(Color::Blue)),
        ]),
        Line::from(vec![
            Span::styled("    ╚═╝ ╚═════╝    ╚═╝        ", Style::default().fg(Color::Blue)),
            Span::styled("╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝", Style::default().fg(Color::Blue)),
        ]),
    ];

    let logo = Paragraph::new(logo_lines)
        .alignment(Alignment::Center);

    frame.render_widget(logo, area);
}

fn render_system_info(frame: &mut Frame, area: Rect, info: &SystemInfo) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // Header
            Constraint::Min(10),   // Content
        ])
        .split(area);

    // Header with distro info
    let header = Paragraph::new(vec![
        Line::from(vec![
            Span::styled("Welcome to ", Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
            Span::styled(get_distro_name(), Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
            Span::raw(" "),
            Span::styled(get_distro_version(), Style::default().fg(Color::Yellow)),
        ]),
    ])
    .alignment(Alignment::Center)
    .block(Block::default().borders(Borders::BOTTOM).border_style(Style::default().fg(Color::DarkGray)));

    frame.render_widget(header, chunks[0]);

    // System info in a nice panel
    let mut info_text = vec![
        Line::from(vec![
            Span::styled("  Platform: ", Style::default().fg(Color::Yellow)),
            Span::raw(get_machine()),
            Span::raw("  |  "),
            Span::styled("Host: ", Style::default().fg(Color::Yellow)),
            Span::raw(&info.hostname),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("  Kernel:      ", Style::default().fg(Color::Yellow)),
            Span::raw(&info.kernel),
        ]),
        Line::from(vec![
            Span::styled("  Uptime:      ", Style::default().fg(Color::Yellow)),
            Span::raw(&info.uptime),
        ]),
        Line::from(vec![
            Span::styled("  RAUC Slot:   ", Style::default().fg(Color::Yellow)),
            Span::styled(&info.rauc_slot, Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("  CPU Usage:   ", Style::default().fg(Color::Yellow)),
            Span::styled(format!("{:.1}%", info.cpu_usage), Style::default().fg(Color::Cyan)),
        ]),
        Line::from(vec![
            Span::styled("  Memory:      ", Style::default().fg(Color::Yellow)),
            Span::raw(format!("{:.1} / {:.1} GB ({:.1}%)",
                info.memory_used as f64 / 1024.0 / 1024.0,
                info.memory_total as f64 / 1024.0 / 1024.0,
                (info.memory_used as f64 / info.memory_total as f64) * 100.0
            )),
        ]),
    ];

    if let Some(temp) = info.cpu_temp {
        info_text.push(Line::from(vec![
            Span::styled("  CPU Temp:    ", Style::default().fg(Color::Yellow)),
            Span::styled(format!("{:.1}°C", temp),
                if temp > 70.0 { Style::default().fg(Color::Red) }
                else if temp > 60.0 { Style::default().fg(Color::Yellow) }
                else { Style::default().fg(Color::Green) }
            ),
        ]));
    }

    info_text.push(Line::from(""));
    info_text.push(Line::from(vec![
        Span::styled("  Network:", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
    ]));
    for ip in &info.ip_addrs {
        info_text.push(Line::from(vec![
            Span::raw("    "),
            Span::styled("→ ", Style::default().fg(Color::DarkGray)),
            Span::raw(ip),
        ]));
    }

    info_text.push(Line::from(""));
    info_text.push(Line::from(vec![
        Span::styled("  Features: ", Style::default().fg(Color::Yellow)),
        Span::styled("RAUC A/B OTA", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)),
        Span::raw(" | "),
        Span::styled("OpenThread Border Router", Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD)),
    ]));

    let info_widget = Paragraph::new(info_text)
        .block(Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(Color::DarkGray))
            .title(" System Information ")
            .title_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)))
        .wrap(Wrap { trim: true });

    frame.render_widget(info_widget, chunks[1]);
}

fn ui(frame: &mut Frame, info: &SystemInfo) {
    let size = frame.size();

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(8),  // Logo
            Constraint::Min(15),    // System info
            Constraint::Length(3),  // Footer
        ])
        .split(size);

    render_logo(frame, chunks[0]);
    render_system_info(frame, chunks[1], info);

    // Footer
    let footer = Paragraph::new(vec![
        Line::from(vec![
            Span::styled("Documentation: ", Style::default().fg(Color::Cyan)),
            Span::raw("https://github.com/your-org/iot-gateway  |  "),
            Span::styled("Support: ", Style::default().fg(Color::Cyan)),
            Span::raw("IoT Gateway Development Team"),
        ]),
    ])
    .alignment(Alignment::Center)
    .block(Block::default().borders(Borders::TOP).border_style(Style::default().fg(Color::DarkGray)));

    frame.render_widget(footer, chunks[2]);
}

fn main() -> Result<()> {
    let info = SystemInfo::new();

    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Clear and render
    terminal.clear()?;
    terminal.draw(|f| ui(f, &info))?;

    // Wait for user to see it (5 seconds)
    std::thread::sleep(std::time::Duration::from_secs(5));

    // Restore terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    Ok(())
}
