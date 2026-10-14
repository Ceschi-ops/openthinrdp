#!/usr/bin/python3
# Remote screen (remote-screen.sh): serves the noVNC viewer and bridges its WebSocket to x11vnc, on 127.0.0.1 only;
# the administrator reaches it through the SSH tunnel the manager opens. Standard library only: websockify would
# bring about 50 MB of Python dependencies to the device.
#   vncbridge.py LISTEN_PORT VNC_PORT WEB_DIR
import base64, hashlib, http.server, socket, socketserver, struct, sys, threading

GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
LPORT, VPORT, WEB = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]


def frame(op, data):
    n = len(data)
    if n < 126:
        head = struct.pack('>BB', 0x80 | op, n)
    elif n < 65536:
        head = struct.pack('>BBH', 0x80 | op, 126, n)
    else:
        head = struct.pack('>BBQ', 0x80 | op, 127, n)
    return head + data


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=WEB, **k)

    def log_message(self, *a):
        pass

    def read_exact(self, n):
        b = self.rfile.read(n)
        if b is None or len(b) < n:
            raise EOFError
        return b

    def send(self, op, data):
        with self.lock:
            self.connection.sendall(frame(op, data))

    def vnc_to_browser(self, vnc):
        try:
            while True:
                d = vnc.recv(65536)
                if not d:
                    break
                self.send(2, d)
        except OSError:
            pass
        finally:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() != 'websocket':
            return super().do_GET()
        key = self.headers.get('Sec-WebSocket-Key', '')
        accept = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        if 'binary' in self.headers.get('Sec-WebSocket-Protocol', ''):
            self.send_header('Sec-WebSocket-Protocol', 'binary')
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        self.lock = threading.Lock()
        try:
            vnc = socket.create_connection(('127.0.0.1', VPORT))
        except OSError:
            return
        threading.Thread(target=self.vnc_to_browser, args=(vnc,), daemon=True).start()
        try:
            while True:
                b0, b1 = self.read_exact(2)
                op, n = b0 & 0x0F, b1 & 0x7F
                if n == 126:
                    n = struct.unpack('>H', self.read_exact(2))[0]
                elif n == 127:
                    n = struct.unpack('>Q', self.read_exact(8))[0]
                mask = self.read_exact(4) if b1 & 0x80 else b'\0\0\0\0'
                data = bytes(c ^ mask[i & 3] for i, c in enumerate(self.read_exact(n)))
                if op == 8:      # close
                    break
                if op == 9:      # ping
                    self.send(10, data)
                elif op in (0, 1, 2):
                    vnc.sendall(data)
        except (EOFError, OSError, ValueError):
            pass
        finally:
            try:
                vnc.close()
            except OSError:
                pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server(('127.0.0.1', LPORT), Handler).serve_forever()
