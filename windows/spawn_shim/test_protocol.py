"""End-to-end check of baocode-spawn.exe's wire protocol (Windows).

Build the service first (see CMakeLists.txt), then: python test_protocol.py
"""
import os, socket, struct, subprocess, time, sys

PORT = 49211
TOKEN = "deadbeef"
EXE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "baocode-spawn.exe")

def u16(s): return s.encode('utf-16-le')

# Start service.
p = subprocess.Popen([EXE, '--port', str(PORT), '--token', TOKEN],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(0.5)
if p.poll() is not None:
    print("service exited early", p.returncode, p.stderr.read()); sys.exit(1)

try:
    s = socket.create_connection(('127.0.0.1', PORT), timeout=3)
    s.sendall((TOKEN + '\n').encode())
    # Command line: cmd.exe /c "echo hello & exit 7" (UTF-16LE, NUL not needed)
    cmd = u16('cmd.exe /c echo hello spawned & exit 7')
    cwd = u16(r'C:\Windows')
    env = b''  # inherit
    req = struct.pack('<IIIII', len(cmd), len(cwd), len(env), 0, 0) + cmd + cwd + env
    s.sendall(req)

    stdout = b''
    stderr = b''
    exit_code = None
    pid = None
    s.settimeout(8)
    buf = b''
    import struct as st
    while True:
        while len(buf) < 8:
            chunk = s.recv(4096)
            if not chunk: break
            buf += chunk
        if len(buf) < 8: break
        t, n = st.unpack('<II', buf[:8])
        while len(buf) < 8 + n:
            buf += s.recv(4096)
        body = buf[8:8+n]
        buf = buf[8+n:]
        if t == 1: stdout += body
        elif t == 2: stderr += body
        elif t == 3:
            exit_code = st.unpack('<i', body[:4])[0]; break
        elif t == 4:
            print("FAILED error", st.unpack('<I', body[:4])[0]); break
        elif t == 5:
            pid = st.unpack('<I', body[:4])[0]
    s.close()
    print("pid", pid)
    print("stdout", stdout)
    print("stderr", stderr)
    print("exit", exit_code)
    ok = exit_code == 7 and b'hello spawned' in stdout
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 2)
finally:
    p.terminate()
    try: p.wait(timeout=3)
    except: p.kill()
