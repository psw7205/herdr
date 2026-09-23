use super::responses::{encode_error, encode_success};
use crate::{
    api::schema::{
        AgentBoundInputParams, AgentTarget, BoundInput, Method, Request, ResponseResult,
    },
    app::App,
};
use bytes::Bytes;
use std::{sync::Arc, time::Duration};

impl App {
    pub(super) fn handle_agent_binding(&mut self, id: String, target: AgentTarget) -> String {
        let Some(binding) = self
            .bound_runtime(&target.target)
            .map(|(_, binding)| binding)
        else {
            return encode_error(
                id,
                "runtime_binding_unavailable",
                "no verified native foreground session",
            );
        };
        encode_success(id, ResponseResult::AgentBinding { binding })
    }

    fn bound_runtime(&self, target: &str) -> Option<(u32, crate::runtime_binding::RuntimeBinding)> {
        let resolved = self.resolve_agent_target(target).ok()?;
        let terminal_id = self
            .state
            .workspaces
            .get(resolved.ws_idx)?
            .terminal_id(resolved.pane_id)?;
        let runtime = self.lookup_runtime_sender(resolved.ws_idx, resolved.pane_id)?;
        let shell = runtime.child_pid()?;
        Some((
            shell,
            crate::runtime_binding::inspect(shell, terminal_id.as_str())?,
        ))
    }

    pub(crate) fn handle_deferred_bound_input(
        &mut self,
        request: Request,
        respond: std::sync::mpsc::Sender<String>,
    ) -> bool {
        let Method::AgentBoundInput(params) = request.method else {
            return false;
        };
        match self.queue_bound_input(&request.id, params) {
            Ok(completion) => {
                std::thread::spawn(move || {
                    let response = match completion.recv() {
                        Ok(Ok(())) => encode_success(request.id, ResponseResult::Ok {}),
                        // Once enqueued, some text may already have been delivered.
                        // Never report a retry-safe rejection or retry automatically.
                        Ok(Err(e)) => encode_error(request.id, "delivery_unknown", e.to_string()),
                        Err(_) => encode_error(
                            request.id,
                            "delivery_unknown",
                            "input completion unavailable",
                        ),
                    };
                    let _ = respond.send(response);
                });
            }
            Err(response) => {
                let _ = respond.send(response);
            }
        }
        true
    }

    fn queue_bound_input(
        &mut self,
        id: &str,
        params: AgentBoundInputParams,
    ) -> Result<std::sync::mpsc::Receiver<std::io::Result<()>>, String> {
        let reject = |code: &str, message: &str| encode_error(id.into(), code, message);
        let Some((shell, binding)) = self.bound_runtime(&params.target) else {
            return Err(reject(
                "session_ended",
                "verified foreground session unavailable",
            ));
        };
        if binding.token != params.binding {
            return Err(reject("runtime_binding_mismatch", "native session changed"));
        }
        let resolved = self
            .resolve_agent_target(&params.target)
            .map_err(|_| reject("session_ended", "agent unavailable"))?;
        let info = self
            .agent_info(resolved.ws_idx, resolved.pane_id)
            .ok_or_else(|| reject("session_ended", "agent unavailable"))?;
        let runtime = self
            .lookup_runtime_sender(resolved.ws_idx, resolved.pane_id)
            .ok_or_else(|| reject("session_ended", "PTY unavailable"))?;
        let (text, enter, delay) = match params.input {
            BoundInput::Prompt { text } => {
                if text.is_empty()
                    || text.len() > 65536
                    || text
                        .chars()
                        .any(|c| c.is_control() && c != '\n' && c != '\t')
                {
                    return Err(reject(
                        "invalid_prompt",
                        "prompt is empty, too large or contains control characters",
                    ));
                }
                if !matches!(
                    info.agent_status,
                    crate::api::schema::AgentStatus::Idle | crate::api::schema::AgentStatus::Done
                ) {
                    return Err(reject(
                        "agent_not_ready",
                        "use Terminal for non-idle interaction",
                    ));
                }
                let (text, enter) =
                    crate::app::api_helpers::encode_api_submission_parts(runtime, &text);
                (text, enter, Duration::from_millis(300))
            }
            BoundInput::Interrupt => {
                let keys = crate::app::api_helpers::encode_api_keys(runtime, &["ctrl+c".into()])
                    .map_err(|_| reject("unsupported_input", "cannot encode interrupt"))?;
                (
                    keys.into_iter().flatten().collect(),
                    Vec::new(),
                    Duration::ZERO,
                )
            }
            BoundInput::TerminalInput { text } => {
                if text.is_empty() || text.len() > 65536 {
                    return Err(reject("invalid_input", "raw input empty or too large"));
                }
                (text.into_bytes(), Vec::new(), Duration::ZERO)
            }
        };
        let guard = Arc::new(move || {
            crate::runtime_binding::inspect(shell, &binding.terminal_id)
                .is_some_and(|current| current.token == binding.token)
        });
        runtime
            .queue_guarded_submission(Bytes::from(text), Bytes::from(enter), delay, guard)
            .map_err(|e| reject("input_rejected", &e.to_string()))
    }
}
