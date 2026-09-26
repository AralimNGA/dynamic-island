import socket, plistlib, struct, sys
def q(msg):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5); s.connect('/var/run/usbmuxd')
    body = plistlib.dumps(dict(msg, ClientVersionString='probe', ProgName='probe', kLibUSBMuxVersion=3))
    s.sendall(struct.pack('<IIII', 16+len(body), 1, 8, 1) + body)
    hdr = s.recv(16); ln = struct.unpack('<I', hdr[:4])[0]; data=b''
    while len(data) < ln-16: data += s.recv(ln-16-len(data))
    return plistlib.loads(data)
for m in ['ListDevices', 'ReadBUID', 'ListListeners']:
    try:
        r = q({'MessageType': m})
        if m == 'ListDevices':
            print(m, [(d.get('Properties',{}).get('ConnectionType'), d.get('Properties',{}).get('SerialNumber','')[:8]+'...') for d in r.get('DeviceList',[])])
        elif m == 'ReadBUID': print(m, 'ok' if 'BUID' in r else r)
        else: print(m, len(r.get('ListenerList', [])), 'listeners')
    except Exception as e: print(m, 'ERR', e)
