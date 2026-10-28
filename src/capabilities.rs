use std::{
    collections::HashMap,
    sync::{Arc, Weak},
};

use nanocode::{HandCapability, HandPermission, HostFuture, hand::HandCapabilities};
use serde::Deserialize;
use serde_json::json;

use crate::bridge::Host;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    name: String,
    description: String,
    #[serde(default)]
    tools: Vec<String>,
}

pub struct Device {
    host: Weak<Host>,
    hand: String,
    specs: Vec<Spec>,
}

impl Device {
    pub fn new(host: &Arc<Host>, hand: String, specs: Vec<Spec>) -> Self {
        Self {
            host: Arc::downgrade(host),
            hand,
            specs,
        }
    }
}

impl HandCapabilities for Device {
    fn capabilities(&self) -> HostFuture<'_, Vec<HandCapability>> {
        Box::pin(async move {
            let answered = match self.host.upgrade() {
                Some(host) => host
                    .call("capability", json!({"hand": self.hand, "op": "list"}))
                    .await
                    .ok()
                    .and_then(|value| {
                        serde_json::from_value::<HashMap<String, HandPermission>>(value).ok()
                    }),
                None => None,
            }
            .unwrap_or_default();
            self.specs
                .iter()
                .map(|spec| HandCapability {
                    name: spec.name.clone(),
                    description: spec.description.clone(),
                    tools: spec.tools.clone(),
                    permission: answered
                        .get(&spec.name)
                        .copied()
                        .unwrap_or(HandPermission::Prompt),
                })
                .collect()
        })
    }

    fn request<'a>(
        &'a self,
        name: &'a str,
        reason: &'a str,
    ) -> HostFuture<'a, Result<HandPermission, String>> {
        Box::pin(async move {
            let host = self.host.upgrade().ok_or("the app stopped")?;
            let value = host
                .call(
                    "capability",
                    json!({"hand": self.hand, "op": "request", "name": name, "reason": reason}),
                )
                .await?;
            serde_json::from_value(value).map_err(|error| error.to_string())
        })
    }
}
