//! Translate each provider's wire format into one dashboard event vocabulary.
use crate::model::{LogKind, MAX_OUTPUT_BYTES, MAX_REASONING_BYTES, Provider, Usage, clip};
use anyhow::{Result, bail};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq)]
pub enum Update {
    TextDelta(String),
    Output(String),
    // Only text supplied by the provider for display; never signatures or encrypted blocks.
    Reasoning(String),
    Log(LogKind, String),
    Session(String),
    Usage(Usage),
    Error(String),
}

pub struct Decoder {
    provider: Provider,
    partial_message: bool,
    reasoning_reported: bool,
    reasoning_blocks: Vec<(String, String)>,
    claude_message_id: Option<String>,
    claude_message_sequence: usize,
    pub final_response: Option<String>,
    pub terminal_seen: bool,
    pub error: Option<String>,
    pub session_id: Option<String>,
    pub question_request: Option<crate::questions::QuestionRequest>,
    question_tool_id: Option<String>,
    harness_usage: Usage,
}

impl Decoder {
    pub fn new(provider: Provider) -> Self {
        Self {
            provider,
            partial_message: false,
            reasoning_reported: false,
            reasoning_blocks: vec![],
            claude_message_id: None,
            claude_message_sequence: 0,
            final_response: None,
            terminal_seen: false,
            error: None,
            session_id: None,
            question_request: None,
            question_tool_id: None,
            harness_usage: Usage { input_tokens: 0, output_tokens: 0, cost_usd: None },
        }
    }

    pub fn line(&mut self, line: &str) -> Vec<Update> {
        match serde_json::from_str::<Value>(line) {
            Ok(value) => self.value(&value),
            Err(_) if !line.trim().is_empty() => vec![Update::Log(LogKind::Info, line.into())],
            _ => vec![],
        }
    }

    pub fn value(&mut self, value: &Value) -> Vec<Update> {
        let mut updates = vec![];
        match self.provider {
            Provider::Codex => self.codex(value, &mut updates),
            Provider::Antigravity => self.antigravity(value, &mut updates),
            Provider::Claude | Provider::Qoder => self.claude_style(value, &mut updates),
            Provider::DeepSeek => self.deepseek(value, &mut updates),
            Provider::Kiro => self.kiro(value, &mut updates),
        }
        for update in &updates {
            if let Update::Session(id) = update {
                self.session_id = Some(id.clone());
            }
            if let Update::Error(error) = update {
                self.error = Some(error.clone());
            }
        }
        updates
    }

    fn codex(&mut self, v: &Value, out: &mut Vec<Update>) {
        match string(v, "type") {
            "thread.started" => session(v, "thread_id", out),
            "turn.started" => out.push(Update::Log(LogKind::Info, "Agent started working".into())),
            "turn.completed" => {
                self.terminal_seen = true;
                usage(v.get("usage"), None, out);
            }
            "turn.failed" | "error" => {
                self.terminal_seen = true;
                out.push(Update::Error(error_text(v.get("error").unwrap_or(v))));
            }
            "item.started" | "item.updated" | "item.completed" => {
                let item = &v["item"];
                let completed = string(v, "type") == "item.completed";
                if string(v, "type") == "item.updated" && string(item, "type") != "reasoning" {
                    return;
                }
                match string(item, "type") {
                    "agent_message" if completed => {
                        if let Some(text) = item["text"].as_str() {
                            self.final_response = Some(text.into());
                            out.push(Update::TextDelta(format!("{text}\n\n")));
                        }
                    }
                    "command_execution" => out.push(Update::Log(
                        LogKind::Tool,
                        format!(
                            "{}: {}",
                            if completed {
                                "Command finished"
                            } else {
                                "Running command"
                            },
                            string(item, "command")
                        ),
                    )),
                    "file_change" if completed => out.push(Update::Log(
                        LogKind::Tool,
                        format!("Files changed: {}", item["changes"]),
                    )),
                    "mcp_tool_call" if !completed => out.push(Update::Log(
                        LogKind::Tool,
                        format!(
                            "Tool: {} / {}",
                            string(item, "server"),
                            string(item, "tool")
                        ),
                    )),
                    "web_search" if !completed => out.push(Update::Log(
                        LogKind::Tool,
                        format!("Search: {}", string(item, "query")),
                    )),
                    "reasoning" => self.reasoning_text(
                        &format!("codex:{}", string(item, "id")),
                        string(item, "text"),
                        false,
                        out,
                    ),
                    _ => out.push(Update::Log(
                        LogKind::Info,
                        format!("{} · {}", string(v, "type"), string(item, "type")),
                    )),
                }
            }
            _ => out.push(Update::Log(
                LogKind::Info,
                format!("Event: {}", string(v, "type")),
            )),
        }
    }

    fn claude_style(&mut self, v: &Value, out: &mut Vec<Update>) {
        match string(v, "type") {
            "system" => {
                session(v, "session_id", out);
                let subtype = string(v, "subtype");
                if subtype == "thinking_tokens" {
                    self.reasoning(out);
                    return;
                }
                out.push(Update::Log(
                    if subtype == "permission_denied" {
                        LogKind::Warning
                    } else {
                        LogKind::Info
                    },
                    if subtype == "init" {
                        format!("Session initialized · {}", string(v, "model"))
                    } else {
                        format!("System: {subtype}")
                    },
                ));
            }
            "stream_event" => {
                if v.get("parent_tool_use_id").is_some_and(|id| !id.is_null()) {
                    return;
                }
                let event = &v["event"];
                if string(event, "type") == "message_start" {
                    self.partial_message = false;
                    self.claude_message_id = None;
                    self.claude_message_key(&event["message"]);
                }
                if string(&event["content_block"], "type") == "thinking" {
                    let key = format!(
                        "{}:{}",
                        self.claude_message_key(&Value::Null),
                        event["index"].as_u64().unwrap_or(0)
                    );
                    self.reasoning_text(
                        &key,
                        string(&event["content_block"], "thinking"),
                        false,
                        out,
                    );
                }
                match string(&event["delta"], "type") {
                    "text_delta" => {
                        self.partial_message = true;
                        out.push(Update::TextDelta(string(&event["delta"], "text").into()));
                    }
                    "thinking_delta" => {
                        let key = format!(
                            "{}:{}",
                            self.claude_message_key(&Value::Null),
                            event["index"].as_u64().unwrap_or(0)
                        );
                        self.reasoning_text(&key, string(&event["delta"], "thinking"), true, out);
                    }
                    _ => {}
                }
                if string(&event["content_block"], "type") == "tool_use" {
                    out.push(Update::Log(
                        LogKind::Tool,
                        format!("Tool: {}", string(&event["content_block"], "name")),
                    ));
                }
            }
            "assistant" | "message" => {
                // Subagent output belongs in activity, not in the main agent's answer.
                if v.get("parent_tool_use_id").is_some_and(|id| !id.is_null()) {
                    out.push(Update::Log(
                        LogKind::Info,
                        "Subagent message received".into(),
                    ));
                    return;
                }
                let message = v.get("message").unwrap_or(v);
                if let Some(content) = message["content"].as_array() {
                    for (index, block) in content.iter().enumerate() {
                        match string(block, "type") {
                            "text" if !self.partial_message => out
                                .push(Update::TextDelta(format!("{}\n\n", string(block, "text")))),
                            "tool_use" if string(block, "name") == "AskUserQuestion" => {
                                if block["input"]["answers"]
                                    .as_object()
                                    .is_none_or(|a| a.is_empty())
                                {
                                    match crate::questions::QuestionRequest::from_value(
                                        &block["input"],
                                    ) {
                                        Ok(request) if self.question_request.is_none() => {
                                            self.question_request = Some(request);
                                            self.question_tool_id =
                                                block["id"].as_str().map(str::to_owned);
                                            out.push(Update::Log(LogKind::Info, "Agent asked for clarification. Answer its question card after this turn.".into()));
                                        }
                                        Err(error) => out.push(Update::Log(
                                            LogKind::Warning,
                                            format!(
                                                "Could not display the agent's question: {error}"
                                            ),
                                        )),
                                        _ => {}
                                    }
                                }
                            }
                            "tool_use" => out.push(Update::Log(
                                LogKind::Tool,
                                format!("Tool: {} · {}", string(block, "name"), block["input"]),
                            )),
                            "thinking" => {
                                let key = format!("{}:{index}", self.claude_message_key(message));
                                self.reasoning_text(&key, string(block, "thinking"), false, out);
                            }
                            _ => {}
                        }
                    }
                } else if let Some(content) = message["content"].as_str() {
                    out.push(Update::TextDelta(content.into()));
                }
                self.claude_message_id = None;
            }
            "user" => {
                if v.get("parent_tool_use_id").is_some_and(|id| !id.is_null()) {
                    return;
                }
                // A host or hook may already have answered a native question. Never ask it again.
                for block in v["message"]["content"].as_array().into_iter().flatten() {
                    if string(block, "type") == "tool_result"
                        && self.question_tool_id.as_deref() == block["tool_use_id"].as_str()
                        && block["is_error"].as_bool() != Some(true)
                    {
                        self.question_request = None;
                        self.question_tool_id = None;
                    }
                }
            }
            "result" => {
                self.terminal_seen = true;
                session(v, "session_id", out);
                if let Some(text) = v["result"].as_str() {
                    self.final_response = Some(text.into());
                    out.push(Update::Output(text.into()));
                }
                usage(v.get("usage"), v["total_cost_usd"].as_f64(), out);
                if v["is_error"].as_bool() == Some(true)
                    || string(v, "subtype").starts_with("error")
                {
                    out.push(Update::Error(error_text(v)));
                }
                if v["permission_denials"]
                    .as_array()
                    .is_some_and(|denials| !denials.is_empty())
                {
                    out.push(Update::Log(LogKind::Warning, "Some tools were denied by the CLI's permission rules. Review the result before relying on task completion.".into()));
                }
            }
            "error" => {
                self.terminal_seen = true;
                out.push(Update::Error(error_text(v)));
            }
            _ => out.push(Update::Log(
                LogKind::Info,
                format!("Event: {}", string(v, "type")),
            )),
        }
    }

    // Kiro 2.29 emits tagged run records wrapping ACP notifications, rather than Claude JSON.
    fn kiro(&mut self, v: &Value, out: &mut Vec<Update>) {
        let data = &v["data"];
        let kind = string(v, "type");
        if let Some(id) = data["sessionId"].as_str() {
            if kind == "sessionUpdate"
                && self.session_id.as_deref().is_some_and(|saved| saved != id)
            {
                return;
            }
            session(data, "sessionId", out);
        }
        match kind {
            "runStarted" => out.push(Update::Log(
                LogKind::Info,
                "Kiro headless session starting".into(),
            )),
            "sessionUpdate" => {
                let update = &data["update"];
                match string(update, "sessionUpdate") {
                    "agent_message_chunk" if string(&update["content"], "type") == "text" => {
                        let text = string(&update["content"], "text");
                        let response = self.final_response.get_or_insert_with(String::new);
                        if response.len() + text.len() > MAX_OUTPUT_BYTES {
                            *response = clip(response, MAX_OUTPUT_BYTES);
                            out.push(Update::Error(
                                "Kiro response exceeded the 256 KiB output limit.".into(),
                            ));
                        } else {
                            response.push_str(text);
                            out.push(Update::TextDelta(text.into()));
                        }
                    }
                    "agent_thought_chunk" if string(&update["content"], "type") == "text" => {
                        self.reasoning_text("kiro", string(&update["content"], "text"), true, out);
                    }
                    "tool_call" | "tool_call_update" => out.push(Update::Log(
                        LogKind::Tool,
                        format!(
                            "Kiro tool: {} · {}",
                            string(update, "title"),
                            string(update, "status")
                        ),
                    )),
                    _ => {}
                }
            }
            "runFinished" => {
                self.terminal_seen = true;
                let result = data.get("result").filter(|r| r.is_object()).unwrap_or(data);
                if let Some(text) = data["finalText"].as_str() {
                    self.final_response = Some(clip(text, MAX_OUTPUT_BYTES));
                    out.push(Update::Output(clip(text, MAX_OUTPUT_BYTES)));
                }
                if let Some(tokens) = result.get("usage") {
                    out.push(Update::Usage(Usage {
                        input_tokens: tokens["inputTokens"].as_u64().unwrap_or(0),
                        output_tokens: tokens["outputTokens"].as_u64().unwrap_or(0),
                        cost_usd: None,
                    }));
                }
                if data["finalTextTruncated"].as_bool() == Some(true) {
                    out.push(Update::Error("Kiro truncated the response. Continue the task to request the remaining work.".into()));
                } else if string(result, "stopReason") != "end_turn"
                    || string(data, "status") != "success"
                {
                    out.push(Update::Error(format!(
                        "Kiro stopped before completing the turn ({} · {})",
                        string(data, "status"),
                        string(result, "stopReason")
                    )));
                }
            }
            "runError" => {
                self.terminal_seen = true;
                out.push(Update::Error(error_text(data.get("error").unwrap_or(data))));
            }
            _ => out.push(Update::Log(LogKind::Info, format!("Kiro event: {kind}"))),
        }
    }

    fn antigravity(&mut self, v: &Value, out: &mut Vec<Update>) {
        match string(v, "event") {
            "init" => {
                session(v, "conversation_id", out);
                out.push(Update::Log(
                    LogKind::Info,
                    "Antigravity session initialized".into(),
                ));
            }
            "step_update" => {
                let step = &v["step_update"];
                if let Some(delta) = step["text_delta"].as_str() {
                    out.push(Update::TextDelta(delta.into()));
                }
                if string(step, "step_type") == "tool" {
                    out.push(Update::Log(
                        LogKind::Tool,
                        format!("{} · {}", string(step, "tool_name"), string(step, "state")),
                    ));
                }
                if !step["tool_info"]["error"].is_null() {
                    out.push(Update::Log(
                        LogKind::Warning,
                        error_text(&step["tool_info"]["error"]),
                    ));
                }
            }
            "result" => {
                self.terminal_seen = true;
                let result = &v["result"];
                session(result, "conversation_id", out);
                if let Some(text) = result["response"].as_str() {
                    self.final_response = Some(text.into());
                    out.push(Update::Output(text.into()));
                }
                usage(result.get("usage"), None, out);
                if string(result, "status") != "SUCCESS" {
                    out.push(Update::Error(error_text(result)));
                }
            }
            _ => out.push(Update::Log(
                LogKind::Info,
                format!("Event: {}", string(v, "event")),
            )),
        }
    }

    fn deepseek(&mut self, v: &Value, out: &mut Vec<Update>) {
        if !string(v, "type").is_empty() {
            self.deepseek_harness(v, out);
            return;
        }
        if let Some(error) = v.get("error") {
            out.push(Update::Error(error_text(error)));
        }
        if let Some(delta) = v["choices"][0]["delta"]["content"].as_str() {
            out.push(Update::TextDelta(delta.into()));
        }
        if let Some(text) = v["choices"][0]["delta"]["reasoning_content"].as_str() {
            self.reasoning_text("deepseek", text, true, out);
        }
        if let Some(reason) = v["choices"][0]["finish_reason"].as_str()
            && matches!(
                reason,
                "length" | "content_filter" | "tool_calls" | "insufficient_system_resource"
            )
        {
            out.push(Update::Error(format!(
                "DeepSeek response incomplete: {reason}"
            )));
        }
        usage(v.get("usage"), None, out);
    }

    fn deepseek_harness(&mut self, v: &Value, out: &mut Vec<Update>) {
        match string(v, "type") {
            "session" => {
                if v["truncated"] == true { out.push(Update::Error("DeepSeek Harness returned a truncated session identity.".into())); }
                else { session(v, "sessionId", out); }
            }
            "text" => out.push(Update::TextDelta(format!("{}\n\n", string(v, "text")))),
            "thinking" => { self.claude_message_sequence += 1; self.reasoning_text(&format!("dsh:{}", self.claude_message_sequence), string(v, "text"), false, out); }
            "tool_call" => out.push(Update::Log(LogKind::Tool, format!("{}: {}", string(v, "tool"), clip(&v["input"].to_string(), 8192)))),
            "tool_result" => out.push(Update::Log(if string(v, "status") == "error" { LogKind::Warning } else { LogKind::Tool }, format!("Tool {} · {}: {}", string(v, "callId"), string(v, "status"), clip(string(v, "result"), 8192)))),
            "status" => {
                if string(v, "phase") == "turn_end" && string(v, "reason") != "completed" {
                    out.push(Update::Error(format!("DeepSeek Harness turn ended: {}", string(v, "reason"))));
                }
                if let Some(usage) = v.get("usage") {
                    self.harness_usage.input_tokens = self.harness_usage.input_tokens.saturating_add(usage["inputTokens"].as_u64().unwrap_or(0));
                    self.harness_usage.output_tokens = self.harness_usage.output_tokens.saturating_add(usage["outputTokens"].as_u64().unwrap_or(0));
                    out.push(Update::Usage(self.harness_usage.clone()));
                }
            }
            "final" => {
                self.terminal_seen = true;
                self.final_response = Some(clip(string(v, "text"), MAX_OUTPUT_BYTES));
                out.push(Update::Output(self.final_response.clone().unwrap_or_default()));
            }
            "error" => { self.terminal_seen = true; out.push(Update::Error(error_text(v))); }
            _ => {}
        }
    }

    fn reasoning(&mut self, out: &mut Vec<Update>) {
        if !self.reasoning_reported {
            out.push(Update::Log(LogKind::Info, "Thinking…".into()));
            self.reasoning_reported = true;
        }
    }

    fn claude_message_key(&mut self, message: &Value) -> String {
        if let Some(id) = &self.claude_message_id {
            return id.clone();
        }
        self.claude_message_sequence += 1;
        let id = if let Some(id) = message["id"].as_str() {
            format!("claude:{}", clip(id, 256))
        } else {
            format!("claude-message-{}", self.claude_message_sequence)
        };
        self.claude_message_id = Some(id.clone());
        id
    }

    fn reasoning_text(&mut self, key: &str, text: &str, append: bool, out: &mut Vec<Update>) {
        self.reasoning(out);
        if text.is_empty() {
            return;
        }
        let key = clip(key, 320);
        let index = match self.reasoning_blocks.iter().position(|(id, _)| id == &key) {
            Some(index) => index,
            None => {
                let used: usize = self
                    .reasoning_blocks
                    .iter()
                    .map(|(_, text)| text.len() + 2)
                    .sum();
                if self.reasoning_blocks.len() >= 128 || used >= MAX_REASONING_BYTES {
                    return;
                }
                self.reasoning_blocks.push((key, String::new()));
                self.reasoning_blocks.len() - 1
            }
        };
        let other_bytes = self
            .reasoning_blocks
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != index)
            .map(|(_, (_, text))| text.len())
            .sum::<usize>()
            + self.reasoning_blocks.len().saturating_sub(1) * 2;
        let limit = MAX_REASONING_BYTES.saturating_sub(other_bytes);
        let current = &self.reasoning_blocks[index].1;
        let next = if append {
            if current.len() >= limit {
                return;
            }
            format!("{current}{}", clip(text, limit - current.len()))
        } else {
            clip(text, limit)
        };
        if next == *current {
            return;
        }
        self.reasoning_blocks[index].1 = next;
        out.push(Update::Reasoning(
            self.reasoning_blocks
                .iter()
                .map(|(_, text)| text.as_str())
                .collect::<Vec<_>>()
                .join("\n\n"),
        ));
    }
}

fn string<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}

fn session(v: &Value, key: &str, out: &mut Vec<Update>) {
    if let Some(id) = v[key].as_str() {
        out.push(Update::Session(id.into()));
    }
}

fn usage(value: Option<&Value>, cost: Option<f64>, out: &mut Vec<Update>) {
    let Some(v) = value.filter(|v| !v.is_null()) else {
        return;
    };
    out.push(Update::Usage(Usage {
        input_tokens: v["input_tokens"]
            .as_u64()
            .or_else(|| v["prompt_tokens"].as_u64())
            .unwrap_or(0),
        output_tokens: v["output_tokens"]
            .as_u64()
            .or_else(|| v["completion_tokens"].as_u64())
            .unwrap_or(0),
        cost_usd: cost,
    }));
}

fn error_text(v: &Value) -> String {
    for key in ["message", "error", "errors", "result"] {
        if let Some(s) = v[key].as_str().filter(|s| !s.is_empty()) {
            return s.into();
        }
        if let Some(array) = v[key].as_array() {
            return array
                .iter()
                .map(|s| {
                    s.as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| s.to_string())
                })
                .collect::<Vec<_>>()
                .join("\n");
        }
    }
    if let Some(s) = v.as_str() {
        s.into()
    } else {
        v.to_string()
    }
}

/// SSE framing buffers bytes, so network chunks can split JSON, CRLF, and UTF-8.
#[derive(Default)]
pub struct SseDecoder {
    buffer: Vec<u8>,
    data: String,
    pub done: bool,
}

impl SseDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Value>> {
        self.buffer.extend_from_slice(bytes);
        let mut out = vec![];
        while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
            let tail = self.buffer.split_off(end + 1);
            let line = std::str::from_utf8(&self.buffer[..end])?.trim_end_matches('\r');
            if line.is_empty() {
                let data = std::mem::take(&mut self.data);
                if data.trim() == "[DONE]" {
                    self.done = true;
                } else if !data.trim().is_empty() {
                    out.push(serde_json::from_str(data.trim())?);
                }
            } else if let Some(data) = line.strip_prefix("data:") {
                self.data.push_str(data.strip_prefix(' ').unwrap_or(data));
                self.data.push('\n');
            }
            self.buffer = tail;
            if self.data.len() > 1024 * 1024 {
                bail!("DeepSeek sent an oversized SSE event");
            }
        }
        if self.buffer.len() > 1024 * 1024 {
            bail!("DeepSeek sent an oversized SSE line");
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_deepseek_harness_projects_sessions_steps_reasoning_and_final_answers() {
        let mut decoder = Decoder::new(Provider::DeepSeek);
        let mut updates = vec![];
        for event in [
            serde_json::json!({"type":"session","sessionId":"session-exact-123"}),
            serde_json::json!({"type":"thinking","text":"Inspect the files."}),
            serde_json::json!({"type":"thinking","text":"Check the tests."}),
            serde_json::json!({"type":"text","text":"Intermediate answer"}),
            serde_json::json!({"type":"tool_call","tool":"read","callId":"call-1","input":{"path":"README.md"}}),
            serde_json::json!({"type":"tool_result","callId":"call-1","status":"completed","result":"Readme content"}),
            serde_json::json!({"type":"status","phase":"step_end","usage":{"inputTokens":10,"outputTokens":3}}),
            serde_json::json!({"type":"status","phase":"step_end","usage":{"inputTokens":20,"outputTokens":4}}),
            serde_json::json!({"type":"status","phase":"turn_end","reason":"completed"}),
            serde_json::json!({"type":"final","text":"Complete answer"}),
        ] { updates.extend(decoder.value(&event)); }
        assert_eq!(decoder.session_id.as_deref(), Some("session-exact-123"));
        assert!(decoder.terminal_seen && decoder.error.is_none());
        assert_eq!(decoder.final_response.as_deref(), Some("Complete answer"));
        assert!(updates.contains(&Update::Output("Complete answer".into())));
        assert!(updates.contains(&Update::Reasoning("Inspect the files.\n\nCheck the tests.".into())));
        assert!(updates.contains(&Update::Usage(Usage { input_tokens: 30, output_tokens: 7, cost_usd: None })));
    }
    #[test]
    fn native_harness_failures_and_truncated_session_ids_are_not_successes() {
        for event in [serde_json::json!({"type":"error","message":"Missing credential"}), serde_json::json!({"type":"status","phase":"turn_end","reason":"aborted"}), serde_json::json!({"type":"session","sessionId":"session-shortened","truncated":true})] {
            let mut decoder = Decoder::new(Provider::DeepSeek);
            decoder.value(&event); decoder.value(&serde_json::json!({"type":"final","text":""}));
            assert!(decoder.error.is_some());
            assert!(decoder.session_id.is_none());
        }
    }
    #[test]
    fn token_heartbeats_are_one_status_not_activity_spam() {
        let mut decoder = Decoder::new(Provider::Claude);
        let updates: Vec<_> = (0..1000)
            .flat_map(|_| {
                decoder.value(&serde_json::json!({"type":"system", "subtype":"thinking_tokens"}))
            })
            .collect();
        assert_eq!(
            updates,
            vec![Update::Log(LogKind::Info, "Thinking…".into())]
        );
    }

    #[test]
    fn claude_streamed_thinking_and_final_snapshots_do_not_duplicate() {
        let mut decoder = Decoder::new(Provider::Claude);
        decoder.value(&serde_json::json!({"type":"stream_event", "event":{"type":"message_start", "message":{"id":"m1"}}}));
        decoder.value(&serde_json::json!({"type":"stream_event", "event":{"type":"content_block_start", "index":0, "content_block":{"type":"thinking", "thinking":""}}}));
        let mut updates = vec![];
        for text in ["Inspect ", "the change."] {
            updates.extend(decoder.value(&serde_json::json!({"type":"stream_event", "event":{"type":"content_block_delta", "index":0, "delta":{"type":"thinking_delta", "thinking":text}}})));
        }
        assert!(updates.contains(&Update::Reasoning("Inspect the change.".into())));
        let final_updates = decoder.value(&serde_json::json!({"type":"assistant", "message":{"id":"m1", "content":[{"type":"thinking", "thinking":"Inspect the change.", "signature":"not-displayable"}, {"type":"text", "text":"Done"}]}}));
        assert_eq!(final_updates, vec![Update::TextDelta("Done\n\n".into())]);
        let next = decoder.value(&serde_json::json!({"type":"assistant", "message":{"id":"m2", "content":[{"type":"thinking", "thinking":"Check tests."}]}}));
        assert_eq!(
            next,
            vec![Update::Reasoning(
                "Inspect the change.\n\nCheck tests.".into()
            )]
        );
        assert!(decoder.value(&serde_json::json!({"type":"stream_event", "event":{"delta":{"type":"signature_delta", "signature":"private"}}})).is_empty());
        assert!(decoder.value(&serde_json::json!({"type":"assistant", "message":{"content":[{"type":"redacted_thinking", "data":"encrypted"}]}})).is_empty());
        assert!(decoder.value(&serde_json::json!({"type":"stream_event", "parent_tool_use_id":"child", "event":{"delta":{"type":"thinking_delta", "thinking":"child text"}}})).is_empty());
    }

    #[test]
    fn full_message_thinking_works_without_partial_events() {
        let mut decoder = Decoder::new(Provider::Qoder);
        let updates = decoder.value(&serde_json::json!({"type":"assistant", "message":{"content":[{"type":"thinking", "thinking":"Read the workspace."}, {"type":"text", "text":"Answer"}]}}));
        assert!(updates.contains(&Update::Reasoning("Read the workspace.".into())));
        assert!(updates.contains(&Update::TextDelta("Answer\n\n".into())));
    }

    #[test]
    fn codex_reasoning_items_are_revised_and_kept_separate_from_answers() {
        let mut decoder = Decoder::new(Provider::Codex);
        for (kind, text) in [
            ("item.started", ""),
            ("item.updated", "Read"),
            ("item.updated", "Read code."),
            ("item.completed", "Read code."),
        ] {
            let updates = decoder.value(
                &serde_json::json!({"type":kind,"item":{"id":"r1","type":"reasoning","text":text}}),
            );
            if kind == "item.completed" {
                assert!(updates.is_empty());
            }
        }
        assert_eq!(decoder.value(&serde_json::json!({"type":"item.completed","item":{"id":"r2","type":"reasoning","text":"Check tests."}})), vec![Update::Reasoning("Read code.\n\nCheck tests.".into())]);
        assert_eq!(decoder.value(&serde_json::json!({"type":"item.completed","item":{"id":"a1","type":"agent_message","text":"Done"}})), vec![Update::TextDelta("Done\n\n".into())]);
        assert_eq!(decoder.final_response.as_deref(), Some("Done"));
    }

    #[test]
    fn deepseek_and_kiro_reasoning_chunks_are_separate_and_session_scoped() {
        let mut deepseek = Decoder::new(Provider::DeepSeek);
        deepseek
            .value(&serde_json::json!({"choices":[{"delta":{"reasoning_content":"Consider "}}]}));
        let updates = deepseek.value(&serde_json::json!({"choices":[{"delta":{"reasoning_content":"options.", "content":"Answer"}}]}));
        assert_eq!(
            updates,
            vec![
                Update::TextDelta("Answer".into()),
                Update::Reasoning("Consider options.".into())
            ]
        );
        let mut kiro = Decoder::new(Provider::Kiro);
        let chunk = |session: &str, text: &str| serde_json::json!({"type":"sessionUpdate", "data":{"sessionId":session, "update":{"sessionUpdate":"agent_thought_chunk", "content":{"type":"text", "text":text}}}});
        kiro.value(&chunk("main", "Consider "));
        assert!(kiro.value(&chunk("child", "unrelated")).is_empty());
        assert!(
            kiro.value(&chunk("main", "options."))
                .contains(&Update::Reasoning("Consider options.".into()))
        );
    }

    #[test]
    fn reasoning_is_bounded_and_snapshots_can_still_be_revised() {
        let mut decoder = Decoder::new(Provider::DeepSeek);
        let updates = decoder.value(&serde_json::json!({"choices":[{"delta":{"reasoning_content":"世".repeat(MAX_REASONING_BYTES)}}]}));
        let text = updates
            .iter()
            .find_map(|u| {
                if let Update::Reasoning(text) = u {
                    Some(text)
                } else {
                    None
                }
            })
            .unwrap();
        assert!(text.len() <= MAX_REASONING_BYTES && text.ends_with('…'));
        assert!(
            decoder
                .value(&serde_json::json!({"choices":[{"delta":{"reasoning_content":"more"}}]}))
                .is_empty()
        );
        let mut codex = Decoder::new(Provider::Codex);
        codex.reasoning_text("one", &"x".repeat(MAX_REASONING_BYTES), false, &mut vec![]);
        let mut revised = vec![];
        codex.reasoning_text("one", "Short summary", false, &mut revised);
        assert_eq!(revised, vec![Update::Reasoning("Short summary".into())]);
        for i in 0..200 {
            codex.reasoning_text(&i.to_string(), "summary", false, &mut vec![]);
        }
        assert_eq!(codex.reasoning_blocks.len(), 128);
    }

    #[test]
    fn native_clarifying_questions_are_retained_only_when_unanswered() {
        let input = serde_json::json!({"questions":[{"question":"Which approach?", "header":"Scope", "options":[{"label":"Small","description":"Focused"},{"label":"Full","description":"Complete"}], "multiSelect":false}]});
        let mut decoder = Decoder::new(Provider::Claude);
        let call = serde_json::json!({"type":"assistant", "parent_tool_use_id":null, "message":{"content":[{"type":"tool_use", "id":"ask-1", "name":"AskUserQuestion", "input":input}]}});
        decoder.value(&call);
        assert_eq!(
            decoder.question_request.as_ref().unwrap().questions[0]
                .options
                .len(),
            2
        );
        decoder.value(&serde_json::json!({"type":"user", "message":{"content":[{"type":"tool_result", "tool_use_id":"ask-1", "is_error":true, "content":"Denied in headless mode"}]}}));
        assert!(decoder.question_request.is_some());
        decoder.value(&serde_json::json!({"type":"user", "message":{"content":[{"type":"tool_result", "tool_use_id":"ask-1", "content":"User chose Small"}]}}));
        assert!(decoder.question_request.is_none());
        let mut subagent = call.clone();
        subagent["parent_tool_use_id"] = serde_json::json!("child-1");
        decoder.value(&subagent);
        assert!(decoder.question_request.is_none());
    }
    #[test]
    fn kiro_wraps_acp_chunks_and_preserves_the_main_session() {
        let mut decoder = Decoder::new(Provider::Kiro);
        decoder.line(r#"{"type":"runStarted","data":{"payloadSchema":"acp","acpProtocolVersion":1,"engine":"v3"}}"#);
        let update = decoder.line(r#"{"type":"sessionUpdate","data":{"sessionId":"main-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello "}}}}"#);
        assert!(update.contains(&Update::TextDelta("Hello ".into())));
        assert_eq!(decoder.session_id.as_deref(), Some("main-session"));
        assert!(decoder.line(r#"{"type":"sessionUpdate","data":{"sessionId":"child-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"unrelated"}}}}"#).is_empty());
        decoder.line(r#"{"type":"sessionUpdate","data":{"sessionId":"main-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"world"}}}}"#);
        let finished = decoder.line(r#"{"type":"runFinished","data":{"status":"success","stopReason":"end_turn","finalText":"Hello world","finalTextTruncated":false,"usage":{"inputTokens":17,"outputTokens":9}}}"#);
        assert!(decoder.terminal_seen && decoder.error.is_none());
        assert_eq!(decoder.final_response.as_deref(), Some("Hello world"));
        assert!(finished.contains(&Update::Usage(Usage {
            input_tokens: 17,
            output_tokens: 9,
            cost_usd: None
        })));
    }

    #[test]
    fn kiro_errors_interruptions_and_truncation_are_not_successes() {
        for record in [
            r#"{"type":"runError","data":{"sessionId":"main-session","stage":"prompt","message":"Authentication failed"}}"#,
            r#"{"type":"runFinished","data":{"status":"interrupted","stopReason":"end_turn","finalText":"Partial"}}"#,
            r#"{"type":"runFinished","data":{"status":"interrupted","stopReason":"cancelled","finalText":"Partial"}}"#,
            r#"{"type":"runFinished","data":{"status":"success","stopReason":"max_tokens","finalText":"Partial"}}"#,
            r#"{"type":"runFinished","data":{"status":"success","stopReason":"end_turn","finalText":"Partial","finalTextTruncated":true}}"#,
        ] {
            let mut decoder = Decoder::new(Provider::Kiro);
            decoder.line(record);
            assert!(decoder.terminal_seen && decoder.error.is_some());
        }
    }
    use serde_json::json;

    #[test]
    fn codex_reads_messages_usage_and_semantic_failure() {
        let mut d = Decoder::new(Provider::Codex);
        assert_eq!(
            d.value(
                &json!({"type":"item.completed","item":{"type":"agent_message","text":"done"}})
            ),
            vec![Update::TextDelta("done\n\n".into())]
        );
        assert_eq!(
            d.value(&json!({"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}})),
            vec![Update::Usage(Usage {
                input_tokens: 7,
                output_tokens: 3,
                cost_usd: None
            })]
        );
        d.value(&json!({"type":"turn.failed","error":{"message":"quota exceeded"}}));
        assert_eq!(d.error.as_deref(), Some("quota exceeded"));
    }

    #[test]
    fn streamed_claude_message_is_not_duplicated_and_result_replaces_deltas() {
        let mut d = Decoder::new(Provider::Claude);
        d.value(
            &json!({"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hi"}}}),
        );
        assert!(
            d.value(
                &json!({"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}]}})
            )
            .is_empty()
        );
        assert_eq!(
            d.value(&json!({"type":"result","result":"Hi"})),
            vec![Update::Output("Hi".into())]
        );
        assert!(d.terminal_seen);
    }

    #[test]
    fn qoder_result_failure_is_not_a_successful_exit() {
        let mut d = Decoder::new(Provider::Qoder);
        d.value(&json!({"type":"result","is_error":true,"result":"Sign in first"}));
        assert_eq!(d.error.as_deref(), Some("Sign in first"));
    }

    #[test]
    fn antigravity_uses_event_and_nested_result() {
        let mut d = Decoder::new(Provider::Antigravity);
        assert_eq!(d.value(&json!({"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"hello"}})), vec![Update::TextDelta("hello".into())]);
        d.value(&json!({"event":"result","result":{"status":"ERROR","error":"Not authenticated"}}));
        assert_eq!(d.error.as_deref(), Some("Not authenticated"));
    }

    #[test]
    fn sse_handles_every_byte_boundary_crlf_and_multiline_data() {
        let wire = "data: {\r\ndata: \"choices\": [{\"delta\": {\"content\": \"世界\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n";
        let mut sse = SseDecoder::default();
        let mut values = vec![];
        for byte in wire.as_bytes() {
            values.extend(sse.push(&[*byte]).unwrap());
        }
        assert_eq!(values[0]["choices"][0]["delta"]["content"], "世界");
        assert!(sse.done);
        assert_eq!(values.len(), 1);
    }

    #[test]
    fn deepseek_truncation_is_a_failure() {
        let mut d = Decoder::new(Provider::DeepSeek);
        d.value(&json!({"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}));
        assert!(d.error.unwrap().contains("incomplete"));
    }

    #[test]
    fn malformed_sse_is_reported() {
        assert!(SseDecoder::default().push(b"data: not-json\n\n").is_err());
    }
}
