//! Small blocking HTTP client for the Daemon API.

use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

/// `$POMO_HOME` or `~/.pomo`.
pub fn default_home() -> PathBuf {
    if let Some(h) = std::env::var_os("POMO_HOME") {
        return PathBuf::from(h);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join(".pomo")
}

#[derive(Debug)]
pub enum Failure {
    /// The Daemon cannot be reached (exit code 2).
    Unreachable(String),
    /// The Daemon answered with an error or an unexpected body (exit code 1).
    Api { status: u16, body: Value, message: String },
}

impl Failure {
    pub fn message(&self) -> &str {
        match self {
            Failure::Unreachable(m) => m,
            Failure::Api { message, .. } => message,
        }
    }
}

pub struct Client {
    base: String,
    token: String,
    source: Option<String>,
    agent: ureq::Agent,
}

fn not_running(home: &Path, why: &str) -> Failure {
    Failure::Unreachable(format!(
        "pomod is not reachable ({why}). Start it with: pomod --home {}",
        home.display()
    ))
}

impl Client {
    /// Reads `daemon.json` and `token` from `home`.
    pub fn from_home(home: &Path, source: Option<String>) -> Result<Client, Failure> {
        let dj = std::fs::read_to_string(home.join("daemon.json"))
            .map_err(|e| not_running(home, &format!("cannot read daemon.json: {e}")))?;
        let dj: Value = serde_json::from_str(&dj).map_err(|e| not_running(home, &format!("bad daemon.json: {e}")))?;
        let port = dj["port"].as_u64().ok_or_else(|| not_running(home, "daemon.json has no port"))?;
        let token = std::fs::read_to_string(home.join("token"))
            .map_err(|e| not_running(home, &format!("cannot read token: {e}")))?;
        let agent = ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(2)).build();
        Ok(Client { base: format!("http://127.0.0.1:{port}"), token: token.trim().to_string(), source, agent })
    }

    fn request(&self, method: &str, path: &str) -> ureq::Request {
        let mut r = self
            .agent
            .request(method, &format!("{}{path}", self.base))
            .set("Authorization", &format!("Bearer {}", self.token));
        if let Some(s) = &self.source {
            r = r.set("X-Pomo-Source", s);
        }
        r
    }

    fn finish(res: Result<ureq::Response, ureq::Error>) -> Result<ureq::Response, Failure> {
        match res {
            Ok(r) => Ok(r),
            Err(ureq::Error::Status(status, resp)) => {
                let body: Value = resp.into_json().unwrap_or(Value::Null);
                let message = body["error"]["message"]
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("request failed with HTTP {status}"));
                Err(Failure::Api { status, body, message })
            }
            Err(ureq::Error::Transport(t)) => {
                Err(Failure::Unreachable(format!("pomod is not reachable ({t}). Start it with: pomod")))
            }
        }
    }

    fn json(resp: ureq::Response) -> Result<Value, Failure> {
        resp.into_json().map_err(|e| Failure::Api {
            status: 0,
            body: Value::Null,
            message: format!("invalid response from pomod: {e}"),
        })
    }

    pub fn get(&self, path: &str, query: &[(String, String)]) -> Result<Value, Failure> {
        let mut r = self.request("GET", path).timeout(Duration::from_secs(30));
        for (k, v) in query {
            r = r.query(k, v);
        }
        Self::json(Self::finish(r.call())?)
    }

    pub fn post_command(&self, body: &Value) -> Result<Value, Failure> {
        self.post("/v1/commands", body)
    }

    /// POST with a JSON body. Long timeout: pairing and syncing dial other Devices.
    pub fn post(&self, path: &str, body: &Value) -> Result<Value, Failure> {
        let r = self.request("POST", path).timeout(Duration::from_secs(90));
        Self::json(Self::finish(r.send_json(body))?)
    }

    /// Opens `/v1/stream`; yields raw SSE lines.
    pub fn stream(&self) -> Result<BufReader<Box<dyn std::io::Read + Send + Sync>>, Failure> {
        let resp = Self::finish(self.request("GET", "/v1/stream").call())?;
        Ok(BufReader::new(resp.into_reader()))
    }
}
