import { useEffect, useRef } from "react";

const WS_URL = "ws://localhost:3001";

export function useWebSocket() {
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    const ws = new WebSocket(WS_URL);

    ws.onopen = () => {
      console.log("WebSocket connection opened");
      // Send hello message when connection is established
      ws.send("hello-server");
      console.log("Sent 'hello-server' to server");
    };

    ws.onmessage = (event) => {
      const message = event.data;
      console.log(`Received from server: ${message}`);
    };

    ws.onerror = (error) => {
      console.error("WebSocket error:", error);
    };

    ws.onclose = () => {
      console.log("WebSocket connection closed");
    };

    wsRef.current = ws;

    return () => {
      if (wsRef.current) {
        wsRef.current.close();
      }
    };
  }, []);
}

