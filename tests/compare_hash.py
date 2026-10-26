import sys, numpy as np
pc=np.loadtxt(sys.argv[1],dtype=np.int64); n=int(sys.argv[2])
raw=np.fromfile(sys.argv[3],dtype='<u4')[:n*2].reshape(n,2)
h_pc=pc[:n,14].astype(np.uint64)&0xffffffff; h_avr=raw[:,0].astype(np.uint64)
d=np.flatnonzero(h_pc!=h_avr)
cyc=raw[1:,1].astype(np.int64)
print(f'ticks {n}: first mismatch {d[0] if len(d) else "none"}, mismatching {len(d)}; AVR cycles/tick mean {cyc.mean():.0f} max {cyc.max()}')
