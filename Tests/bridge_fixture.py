#!/usr/bin/env python3
"""Disposable TLS IMAP/SMTP fixture. Synthetic credentials only; no external network."""
import argparse
import base64
import json
import pathlib
import re
import socketserver
import ssl
import threading

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True)
parser.add_argument('--starttls', action='store_true')
args = parser.parse_args()
root = pathlib.Path(args.directory)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / 'certificate.pem', root / 'private-key.pem')

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def handle_error(self, request, client_address):
        # Rejected test certificates deliberately terminate the server-side handshake.
        pass

class Handler(socketserver.StreamRequestHandler):
    def setup(self):
        self.secure = not args.starttls
        if self.secure: self.request = context.wrap_socket(self.request, server_side=True)
        super().setup()
    def upgrade(self):
        self.wfile.flush()
        self.request = context.wrap_socket(self.request, server_side=True)
        self.connection = self.request
        self.rfile = self.connection.makefile('rb')
        self.wfile = self.connection.makefile('wb', buffering=0)
        self.secure = True
    def send(self, value):
        self.wfile.write(value.encode()); self.wfile.flush()

class IMAP(Handler):
    def handle(self):
        self.send('* OK Synthetic ProtonX IMAP\r\n')
        authenticated = False
        while line := self.rfile.readline():
            text = line.decode().strip()
            tag, _, command = text.partition(' ')
            upper = command.upper()
            if upper == 'CAPABILITY':
                self.send('* CAPABILITY IMAP4rev1 AUTH=PLAIN' + ('' if self.secure else ' STARTTLS LOGINDISABLED') + '\r\n' + tag + ' OK\r\n')
            elif upper == 'STARTTLS' and not self.secure:
                self.send(tag + ' OK Begin TLS\r\n'); self.upgrade()
            elif not self.secure:
                self.send(tag + ' NO TLS required\r\n')
            elif upper.startswith('AUTHENTICATE PLAIN'):
                self.send('+ \r\n')
                raw = base64.b64decode(self.rfile.readline().strip()).split(b'\0')
                authenticated = len(raw) >= 3 and raw[-2:] == [b'synthetic@example.com', b'synthetic-password']
                self.send(tag + (' OK authenticated\r\n' if authenticated else ' NO wrong credentials\r\n'))
            elif upper.startswith('LOGIN '):
                authenticated = 'synthetic@example.com' in command and 'synthetic-password' in command
                self.send(tag + (' OK authenticated\r\n' if authenticated else ' NO wrong credentials\r\n'))
            elif upper == 'LOGOUT':
                self.send('* BYE\r\n' + tag + ' OK\r\n'); break
            elif not authenticated:
                self.send(tag + ' NO authenticate first\r\n')
            elif upper.startswith('LIST '):
                self.send('* LIST (\\HasNoChildren) "/" "INBOX"\r\n* LIST () "/" "Sent"\r\n' + tag + ' OK\r\n')
            elif upper.startswith(('SELECT ', 'EXAMINE ')):
                self.send('* 2 EXISTS\r\n* OK [UIDVALIDITY 42]\r\n' + tag + ' OK [READ-WRITE]\r\n')
            elif upper.startswith('UID SEARCH'):
                self.send('* SEARCH 1 2\r\n' + tag + ' OK\r\n')
            elif upper.startswith('UID FETCH'):
                match = re.match(r'UID FETCH (\d+) (.*)', command, re.I)
                uid = int(match[1]); section = 'HEADER' if 'HEADER' in match[2].upper() else ''
                content = f'From: Synthetic <sender@example.com>\r\nTo: synthetic@example.com\r\nSubject: Synthetic message {uid}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n'
                if not section: content += 'Synthetic mail body\r\n'
                data = content.encode()
                self.send(f'* {uid} FETCH (UID {uid} BODY[{section}] {{{len(data)}}}\r\n')
                self.wfile.write(data); self.send(')\r\n' + tag + ' OK\r\n')
            else: self.send(tag + ' BAD unsupported command\r\n')

class SMTP(Handler):
    def handle(self):
        self.send('220 synthetic ProtonX SMTP\r\n')
        authenticated = False
        while line := self.rfile.readline():
            command = line.decode().strip(); upper = command.upper()
            if upper.startswith(('EHLO ', 'HELO ')): self.send('250-synthetic\r\n' + ('' if self.secure else '250-STARTTLS\r\n') + '250 AUTH PLAIN\r\n')
            elif upper == 'STARTTLS' and not self.secure:
                self.send('220 Begin TLS\r\n'); self.upgrade()
            elif not self.secure: self.send('530 TLS required\r\n')
            elif upper.startswith('AUTH PLAIN'):
                encoded = command.split(' ')[-1]
                if encoded.upper() == 'PLAIN': self.send('334 \r\n'); encoded = self.rfile.readline().decode().strip()
                raw = base64.b64decode(encoded).split(b'\0')
                authenticated = raw[-2:] == [b'synthetic@example.com', b'synthetic-password']
                self.send('235 Authenticated\r\n' if authenticated else '535 Rejected\r\n')
            elif upper == 'QUIT': self.send('221 Bye\r\n'); break
            elif not authenticated: self.send('530 Authenticate first\r\n')
            elif upper.startswith(('MAIL FROM:', 'RCPT TO:')): self.send('250 OK\r\n')
            elif upper == 'DATA':
                self.send('354 Continue\r\n'); message = bytearray()
                while line := self.rfile.readline():
                    if line == b'.\r\n': break
                    message.extend(line)
                (root / 'sent.eml').write_bytes(message)
                self.send('250 Queued\r\n')
            else: self.send('250 OK\r\n')

imap = Server(('127.0.0.1', 0), IMAP)
smtp = Server(('127.0.0.1', 0), SMTP)
for server in (imap, smtp): threading.Thread(target=server.serve_forever, daemon=True).start()
config = dict(username='synthetic@example.com', password='synthetic-password', imapPort=imap.server_address[1], smtpPort=smtp.server_address[1], directTLS=not args.starttls, certificatePEM=(root / 'certificate.pem').read_text())
(root / 'config.json').write_text(json.dumps(config))
threading.Event().wait()
