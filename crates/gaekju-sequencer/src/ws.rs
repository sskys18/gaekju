use std::net::SocketAddr;

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::Message;
use tracing::warn;

use crate::actor::{Event, SequencerHandle};

pub async fn run_ws(addr: SocketAddr, sequencer: SequencerHandle) -> eyre::Result<()> {
    let listener = TcpListener::bind(addr).await?;
    loop {
        let (stream, _) = listener.accept().await?;
        let rx = sequencer.subscribe();
        tokio::spawn(async move {
            if let Err(err) = handle_client(stream, rx).await {
                warn!(error = %err, "ws client closed");
            }
        });
    }
}

async fn handle_client(stream: TcpStream, mut rx: broadcast::Receiver<Event>) -> eyre::Result<()> {
    let ws = accept_async(stream).await?;
    let (mut write, mut read) = ws.split();
    let mut subscribed = TopicSet::default();

    loop {
        tokio::select! {
            msg = read.next() => {
                let Some(msg) = msg else { break; };
                let msg = msg?;
                if let Message::Text(text) = msg {
                    subscribed.update(&text);
                    write.send(Message::Text("{\"status\":\"subscribed\"}".into())).await?;
                }
            }
            event = rx.recv() => {
                match event {
                    Ok(event) if subscribed.matches(&event) => {
                        write.send(Message::Text(serde_json::to_string(&event)?.into())).await?;
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => break,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
    Ok(())
}

#[derive(Default)]
struct TopicSet {
    all: bool,
    trades: bool,
    book: bool,
    mark: bool,
    user: bool,
}

impl TopicSet {
    fn update(&mut self, text: &str) {
        self.all = text.contains("all");
        self.trades |= text.contains("trades:");
        self.book |= text.contains("book:");
        self.mark |= text.contains("mark:");
        self.user |= text.contains("user:");
    }

    fn matches(&self, event: &Event) -> bool {
        self.all
            || match event {
                Event::Trade { .. } => self.trades || self.user,
                Event::Accepted { .. } => self.book || self.user,
                Event::BatchClosed { .. } => self.mark || self.book,
            }
    }
}
