import { useEffect, useRef, useState } from "react";

const WS_URL = "ws://localhost:3001";

export interface WebSocketMessageHandler {
  (message: any): void;
}

export function useWebSocket(onMessage?: WebSocketMessageHandler) {
  const wsRef = useRef<WebSocket | null>(null);
  const [ws, setWs] = useState<WebSocket | null>(null);
  const onMessageRef = useRef(onMessage);

  // Update the ref when onMessage changes
  useEffect(() => {
    onMessageRef.current = onMessage;
  }, [onMessage]);

  useEffect(() => {
    const ws = new WebSocket(WS_URL);

    ws.onopen = () => {
      console.log("WebSocket connection opened");
      // Send hello message when connection is established
      ws.send(JSON.stringify({ type: "hello", message: "hello-server" }));
      console.log("Sent 'hello-server' to server");
      setWs(ws);
    };

    ws.onmessage = (event) => {
      try {
        const message = JSON.parse(event.data);
        console.log(`Received from server:`, message);
        
        // Call the message handler if provided
        if (onMessageRef.current) {
          onMessageRef.current(message);
        }
      }
      catch {
        // Handle non-JSON messages
        console.log(`Received from server: ${event.data}`);
      }
    };

    ws.onerror = (error) => {
      console.error("WebSocket error:", error);
    };

    ws.onclose = () => {
      console.log("WebSocket connection closed");
      setWs(null);
    };

    wsRef.current = ws;

    return () => {
      if (wsRef.current) {
        wsRef.current.close();
      }
    };
  }, []);

  return ws;
}

