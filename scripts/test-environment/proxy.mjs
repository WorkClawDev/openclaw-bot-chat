import http from 'node:http';
import httpProxy from 'http-proxy';

const proxy = httpProxy.createProxyServer({ ws: true, changeOrigin: false });
const bucketPrefix = `/${process.env.STORAGE_S3_BUCKET}/`;
function target(url) {
  const path = new URL(url, 'http://test.local').pathname;
  if (path === '/mqtt') return 'http://emqx:8083';
  if (path.startsWith(bucketPrefix) || path === bucketPrefix.slice(0, -1)) return 'http://storage:9000';
  if (path === '/health' || path.startsWith('/health/') || path.startsWith('/api/')) return 'http://backend:8080';
  return 'http://frontend:3000';
}
proxy.on('error', (_error, _request, response) => {
  if (typeof response.writeHead === 'function') {
    if (!response.headersSent) response.writeHead(502, { 'Content-Type': 'text/plain' });
    response.end('Test service is starting. Please retry.');
  } else {
    response.destroy();
  }
});
const server = http.createServer((request, response) => {
  if (request.url === '/_test/health') {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end('{"status":"ok"}');
    return;
  }
  // Preserve the Host header and path used by S3 signed URLs.
  proxy.web(request, response, { target: target(request.url) });
});
server.on('upgrade', (request, socket, head) => {
  proxy.ws(request, socket, head, { target: target(request.url) });
});
server.listen(3000, '0.0.0.0', () => console.log('Test gateway ready on port 3000'));
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => { proxy.close(); server.close(() => process.exit(0)); });
}
