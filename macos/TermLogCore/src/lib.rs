// SPDX-License-Identifier: GPL-3.0-only
// The backend is imported from the pinned submodule, not copied or translated.
// Only this adapter is new. In particular, no terminal initialization/rendering is linked.
#![allow(dead_code, unused_imports)]

#[path = "../../../vendor/termlog/src/adb.rs"] mod adb;
#[path = "../../../vendor/termlog/src/buffer.rs"] mod buffer;
#[path = "../../../vendor/termlog/src/cli.rs"] mod cli;
#[path = "../../../vendor/termlog/src/clipboard.rs"] mod clipboard;
#[path = "../../../vendor/termlog/src/config.rs"] mod config;
#[path = "../../../vendor/termlog/src/model.rs"] mod model;
#[path = "../../../vendor/termlog/src/parse.rs"] mod parse;
#[path = "../../../vendor/termlog/src/query/mod.rs"] mod query;
#[path = "../../../vendor/termlog/src/util.rs"] mod util;
#[path = "../../../vendor/termlog/src/ui/app.rs"] mod state;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use chrono::Local;
use serde_json::{json, Value};
use state::App;

pub struct TermLogCore { app: App }

fn json_string(value: Value) -> *mut c_char {
    // JSON escapes embedded NULs, so this CString construction cannot fail.
    CString::new(value.to_string()).expect("JSON string").into_raw()
}

unsafe fn argument<'a>(pointer: *const c_char) -> Result<&'a str, String> {
    if pointer.is_null() { return Err("Missing string argument".into()); }
    CStr::from_ptr(pointer).to_str().map_err(|_| "Argument is not UTF-8".into())
}

/// All calls for a handle must be serialized off the UI thread. ADB is configured
/// once by the host before creating a handle; the app uses one Logcat window.
#[no_mangle]
pub unsafe extern "C" fn termlog_create(serial: *const c_char, error: *mut *mut c_char) -> *mut TermLogCore {
    if !error.is_null() { *error = std::ptr::null_mut(); }
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<TermLogCore, String> {
        let serial = argument(serial)?;
        if serial.is_empty() { return Err("Choose an online device".into()); }
        let args = cli::Args { serial: Some(serial.into()), query: None, buffer_size: None, buffers: None, devices: false };
        let app = App::new(args).map_err(|e| e.to_string())?;
        Ok(TermLogCore { app })
    }));
    match result {
        Ok(Ok(core)) => Box::into_raw(Box::new(core)),
        other => {
            let message = match other { Ok(Err(e)) => e, _ => "Logcat backend could not initialize".into() };
            if !error.is_null() { *error = json_string(json!({"error": message})); }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn termlog_request(core: *mut TermLogCore, request: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        let core = core.as_mut().ok_or("Logcat is closed")?;
        let request: Value = serde_json::from_str(argument(request)?).map_err(|e| e.to_string())?;
        dispatch(&mut core.app, &request)
    }));
    json_string(match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"error": error}),
        Err(_) => json!({"error": "Logcat backend request failed"}),
    })
}

#[no_mangle]
pub unsafe extern "C" fn termlog_free_string(pointer: *mut c_char) {
    if !pointer.is_null() { drop(CString::from_raw(pointer)); }
}

#[no_mangle]
pub unsafe extern "C" fn termlog_destroy(pointer: *mut TermLogCore) {
    if !pointer.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let mut core = Box::from_raw(pointer);
            core.app.shutdown();
        }));
    }
}

fn validate_settings(config: &config::Config) -> Result<(), String> {
    if !(1_000..=1_000_000).contains(&config.buffer_size) { return Err("Buffer size must be 1,000–1,000,000 entries".into()); }
    let allowed = ["main", "system", "crash", "events", "radio", "all", "default", "kernel", "security", "stats"];
    if config.buffers.is_empty() || !config.buffers.split(',').all(|b| allowed.contains(&b.trim())) { return Err("Choose valid comma-separated logcat buffers".into()); }
    Ok(())
}

fn dispatch(app: &mut App, request: &Value) -> Result<Value, String> {
    if let Some(serial) = request["expected_serial"].as_str() {
        if serial != app.serial { return Err("Logcat changed device; select the intended device explicitly".into()); }
    }
    app.pump();
    app.tick();
    let action = request["action"].as_str().unwrap_or("snapshot");
    let mut copied: Option<String> = None;
    match action {
        "snapshot" => {},
        "query" => app.apply_query(request["query"].as_str().ok_or("Missing query")?),
        "new_tab" => app.new_tab(),
        "close_tab" => app.close_tab(),
        "tab" => {
            let index = request["index"].as_u64().ok_or("Missing tab index")? as usize;
            if index >= app.tabs.len() { return Err("Tab no longer exists".into()); }
            app.active = index;
        },
        "pause" => {
            app.paused = request["paused"].as_bool().ok_or("Missing pause state")?;
            if !app.paused { app.refilter_now(); }
        },
        "follow" => {
            if request["follow"].as_bool().unwrap_or(true) { app.to_bottom(); }
            else { app.tab_mut().follow = false; }
        },
        "scroll" => {
            let offset = request["offset"].as_u64().unwrap_or(0) as usize;
            let tab = app.tab_mut();
            tab.follow = false;
            tab.offset = offset.min(tab.matched.len().saturating_sub(1));
        },
        "select" | "copy" => {
            if let Some(seq) = request["seq"].as_u64() {
                if let Some(index) = app.tab().matched.iter().position(|s| *s == seq) {
                    let tab = app.tab_mut();
                    tab.selected = index;
                    tab.follow = false;
                } else { return Err("This entry has rolled out of the buffer".into()); }
            }
            if action == "copy" {
                let seq = app.tab().matched.get(app.tab().selected).ok_or("Nothing selected")?;
                copied = Some(app.buffer.get(*seq).ok_or("Entry has rolled out of the buffer")?.message.clone());
            }
        },
        "clear_view" => app.clear_view(),
        // The host must confirm this destructive device operation first.
        "clear_device" => app.clear_device(),
        "device" => {
            let serial = request["serial"].as_str().ok_or("Missing serial")?;
            if !app.devices.iter().any(|d| d.serial == serial && d.is_online()) { return Err("Device is not online".into()); }
            app.switch_device(serial.into());
        },
        "restart" => app.restart_stream(),
        "save_filter" => {
            let name = request["name"].as_str().ok_or("Missing filter name")?.trim();
            if name.is_empty() { return Err("Enter a filter name".into()); }
            let query = app.tab().query_text.clone();
            app.cfg.save_filter(name, &query);
            app.cfg.save();
        },
        "settings" => {
            let mut config: config::Config = serde_json::from_value(request["config"].clone()).map_err(|e| e.to_string())?;
            validate_settings(&config)?;
            // Settings sheets edit preferences, not query history or saved filters.
            config.history = app.cfg.history.clone();
            config.saved = app.cfg.saved.clone();
            config.buffers = config.buffers.split(',').map(str::trim).collect::<Vec<_>>().join(",");
            let restart = app.cfg.buffers != config.buffers;
            app.buffer.set_cap(config.buffer_size);
            app.cfg = config;
            if restart { app.restart_stream(); } else { app.refilter_now(); }
            app.cfg.save();
        },
        "export" => {
            let path = request["path"].as_str().ok_or("Missing export path")?;
            app.export(path);
        },
        _ => return Err(format!("Unknown Logcat action: {action}")),
    }
    let mut result = snapshot(app, request);
    if let Some(message) = copied { result["copied"] = Value::String(message); }
    Ok(result)
}

fn row_value(entry: &model::LogEntry, context: &query::EvalCtx) -> Value {
    json!({
        "seq": entry.seq,
        "date": entry.ts.format("%Y-%m-%d").to_string(),
        "time": entry.ts.format("%H:%M:%S%.3f").to_string(),
        "pid": entry.pid, "tid": entry.tid,
        "level": entry.level.short().to_string(),
        "tag": entry.tag, "package": context.package_name(entry.pid),
        "message": entry.message
    })
}

fn snapshot(app: &App, request: &Value) -> Value {
    let tab = app.tab();
    let limit = request["limit"].as_u64().unwrap_or(200).clamp(1, 500) as usize;
    let offset = if tab.follow { tab.matched.len().saturating_sub(limit) }
        else { request["offset"].as_u64().map(|v| v as usize).unwrap_or(tab.offset).min(tab.matched.len().saturating_sub(1)) };
    let ctx = query::EvalCtx { now: Local::now().naive_local(), pid_map: &app.pid_map, mine: &app.mine };
    let rows: Vec<_> = tab.matched.iter().skip(offset).take(limit).filter_map(|seq| app.buffer.get(*seq)).map(|entry| row_value(entry, &ctx)).collect();
    json!({
        "serial": app.serial, "active": app.active, "paused": app.paused,
        "follow": tab.follow, "selected": tab.selected, "offset": offset,
        "matched": tab.matched.len(), "buffered": app.buffer.len(), "seen": app.total_seen,
        "query_error": tab.error, "status": app.status,
        "config": app.cfg, "rows": rows,
        "tabs": app.tabs.iter().enumerate().map(|(index, t)| json!({"index":index, "name":t.name, "query":t.query_text, "count":t.matched.len()})).collect::<Vec<_>>(),
        "devices": app.devices.iter().map(|d| json!({"serial":d.serial, "model":d.model, "state":d.state})).collect::<Vec<_>>()
    })
}

#[cfg(test)]
mod bridge_tests {
    use super::*;
    #[test]
    fn native_rows_preserve_stacktraces_and_resolve_remote_process_packages() {
        let entry = model::LogEntry { seq: 7, ts: chrono::NaiveDate::from_ymd_opt(2026, 10, 11).unwrap().and_hms_milli_opt(12, 0, 0, 123).unwrap(), pid: 42, tid: 43, level: model::Level::Error, tag: "AndroidRuntime".into(), message: "FATAL EXCEPTION: main\n at App.start(App.kt:2)".into() };
        let map = std::collections::HashMap::from([(42, "dev.example.app:remote".into())]);
        let mine = std::collections::HashSet::new();
        let context = query::EvalCtx { now: entry.ts, pid_map: &map, mine: &mine };
        let row = row_value(&entry, &context);
        assert_eq!(row["package"], "dev.example.app");
        assert_eq!(row["message"], "FATAL EXCEPTION: main\n at App.start(App.kt:2)");
        assert_eq!(row["time"], "12:00:00.123");
    }
    #[test]
    fn settings_reject_invalid_buffers_and_unbounded_capacities() {
        let mut config = config::Config::default();
        assert!(validate_settings(&config).is_ok());
        config.buffers = "main,unknown".into();
        assert!(validate_settings(&config).is_err());
        config.buffers = "main,crash".into();
        config.buffer_size = 1_000_001;
        assert!(validate_settings(&config).is_err());
    }
}
