#!/usr/bin/env node

import http from "node:http";
import net from "node:net";

const listenPort = Number.parseInt(process.argv[2] ?? "", 10);
const upstreamPort = Number.parseInt(process.argv[3] ?? "", 10);
const listenHost = process.argv[4] ?? "0.0.0.0";
const upstreamHost = "127.0.0.1";

if (!Number.isInteger(listenPort) || listenPort <= 0 || listenPort > 65535) {
  console.error("[openclaw-nova-proxy] invalid listen port");
  process.exit(1);
}

if (!Number.isInteger(upstreamPort) || upstreamPort <= 0 || upstreamPort > 65535) {
  console.error("[openclaw-nova-proxy] invalid upstream port");
  process.exit(1);
}

const failResponse = (res, error) => {
  if (res.headersSent) {
    res.destroy(error);
    return;
  }

  res.statusCode = 502;
  res.setHeader("Content-Type", "text/plain; charset=utf-8");
  res.end("Bad Gateway");
};

const server = http.createServer((req, res) => {
  const upstreamReq = http.request(
    {
      host: upstreamHost,
      port: upstreamPort,
      method: req.method,
      path: req.url,
      headers: req.headers,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
      upstreamRes.pipe(res);
    },
  );

  upstreamReq.on("error", (error) => failResponse(res, error));
  req.on("error", () => upstreamReq.destroy());
  res.on("close", () => upstreamReq.destroy());
  req.pipe(upstreamReq);
});

server.on("upgrade", (req, socket, head) => {
  const upstream = net.connect({ host: upstreamHost, port: upstreamPort });

  const closeBoth = () => {
    socket.destroy();
    upstream.destroy();
  };

  socket.on("error", closeBoth);
  upstream.on("error", closeBoth);

  upstream.on("connect", () => {
    const headerLines = [];

    for (let index = 0; index < req.rawHeaders.length; index += 2) {
      const key = req.rawHeaders[index];
      const value = req.rawHeaders[index + 1];
      headerLines.push(`${key}: ${value}`);
    }

    upstream.write(
      `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n${headerLines.join("\r\n")}\r\n\r\n`,
    );

    if (head.length > 0) {
      upstream.write(head);
    }

    socket.pipe(upstream);
    upstream.pipe(socket);
  });
});

server.on("clientError", (error, socket) => {
  console.error(`[openclaw-nova-proxy] client error: ${error.message}`);
  socket.destroy();
});

server.on("error", (error) => {
  console.error(`[openclaw-nova-proxy] ${error.message}`);
  process.exit(1);
});

server.listen(listenPort, listenHost, () => {
  console.error(
    `[openclaw-nova-proxy] listening on http://${listenHost}:${listenPort} -> ${upstreamHost}:${upstreamPort}`,
  );
});

const shutdown = () => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
};

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
