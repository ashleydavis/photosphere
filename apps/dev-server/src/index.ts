const PORT = 3001;

const server = Bun.serve({
  port: PORT,
  fetch(req, server) {
    // Upgrade HTTP request to WebSocket
    if (server.upgrade(req)) {
      return; // WebSocket upgrade successful
    }
    return new Response("Expected WebSocket connection", { status: 400 });
  },
  websocket: {
    message(ws, message) {
      const messageText = message.toString();
      console.log(`Received from client: ${messageText}`);
      
      if (messageText === "hello-server") {
        console.log("Sending 'hello-frontend' to client");
        ws.send("hello-frontend");
      }
    },
    open(ws) {
      console.log("WebSocket connection opened");
    },
    close(ws) {
      console.log("WebSocket connection closed");
    },
  },
});

console.log(`WebSocket server running on ws://localhost:${PORT}`);

