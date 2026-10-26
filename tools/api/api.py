"""Minimal client for the cuzebox-ex TCP API (headless emulator). CUZEBOX=/path/to/cuzebox.
   e = Emu(rom); e.run(frames); e.cmd("SET_INPUT 0 <mask> <frames>"); e.cmd("SCREENSHOT f.png"); e.close()"""
import socket, json, time, subprocess, os
class Emu:
    def __init__(self, hexfile, port=24690):
        self.p = subprocess.Popen(['stdbuf', '-o0', '-e0', os.environ.get('CUZEBOX', 'cuzebox'), '--headless', '--paused', '--unthrottled', '--api-port', str(port), hexfile],
                                  cwd=os.path.dirname(hexfile), stdout=open(os.path.join(os.path.dirname(hexfile),'emu_out.txt'),'w'), stderr=subprocess.STDOUT)
        for _ in range(100):
            try: self.s = socket.create_connection(('127.0.0.1', port)); break
            except OSError: time.sleep(0.1)
        self.f = self.s.makefile('rwb')
        self.f.readline()                                      # greeting
    def cmd(self, line):
        self.f.write((line + '\n').encode()); self.f.flush()
        while True:
            r = self.f.readline().decode().strip()
            if not r: continue
            try: j = json.loads(r)
            except ValueError: continue
            if 'event' in j and 'ok' not in j: continue      # asynchronous events
            return j
    def frame(self):
        return self.cmd('GET_STATE').get('frame', 0)
    def run(self, n):
        target = self.frame() + n
        self.cmd(f'RUN_FRAMES {n}')
        return self.cmd(f'WAIT_FRAME {target} {n + 600}')
    def sym(self, name):
        r = self.cmd(f'READ_SYMBOL {name}')
        return r
    def addr(self, name):
        if not hasattr(self, '_addr'): self._addr = {}
        if name not in self._addr: self._addr[name] = self.cmd(f'READ_SYMBOL {name}')['addr']
        return self._addr[name]
    def long(self, name, signed=True):
        v = self.cmd(f'READ_MEM SRAM {self.addr(name)} 4')['values']
        x = v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24
        return x - (1 << 32) if signed and x >= 1 << 31 else x
    def byte(self, name):
        return self.cmd(f'READ_MEM SRAM {self.addr(name)} 1')['values'][0]
    def close(self):
        try: self.cmd('QUIT')
        except Exception: pass
        try: self.p.wait(timeout=5)
        except Exception: self.p.kill()
