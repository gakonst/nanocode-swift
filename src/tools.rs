use std::sync::{Arc, Weak};

use nanocode::{FunctionHandler, FunctionTool, tool_contract::ToolContext};
use nanocode_code_mode::embedded::HostFuture;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::bridge::Host;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostTool {
    pub name: String,
    pub description: String,
    pub parameters: Value,
    #[serde(default)]
    pub content: bool,
}

struct Bridge(Weak<Host>);

impl FunctionHandler for Bridge {
    fn call<'a>(
        &'a self,
        name: &'a str,
        input: Value,
        context: ToolContext<'a>,
    ) -> HostFuture<'a, Result<Value, String>> {
        let body = json!({
            "name": name,
            "input": input,
            "context": {
                "session_id": context.session_id(),
                "call_id": context.call_id(),
                "turn_id": context.turn_id(),
                "model": context.model(),
                "origin": context.host_context(),
            },
        });
        Box::pin(async move {
            let Some(host) = self.0.upgrade() else {
                return Err("the app stopped".into());
            };
            host.call("tool", body).await
        })
    }
}

pub fn tools(host: &Arc<Host>, definitions: Vec<HostTool>) -> impl Iterator<Item = FunctionTool> {
    let bridge: Arc<dyn FunctionHandler> = Arc::new(Bridge(Arc::downgrade(host)));
    definitions.into_iter().map(move |tool| {
        FunctionTool::new(
            tool.name,
            tool.description,
            tool.parameters,
            Arc::clone(&bridge),
        )
        .parallel_tool_calls(true)
        .content_results(tool.content)
    })
}
