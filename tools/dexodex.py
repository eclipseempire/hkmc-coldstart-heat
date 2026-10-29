#!/usr/bin/env python3
# Minimal pure-Python Dalvik ODEX/DEX reader.
# Extracts AIDL transaction codes (static final int TRANSACTION_* from the
# class static_values array) and method signatures. No external deps.
import sys, struct, re

def u2(d,o): return struct.unpack_from('<H', d, o)[0]
def u4(d,o): return struct.unpack_from('<I', d, o)[0]

# Dalvik instruction widths in 16-bit code units, incl. ODEX quick opcodes.
WIDTHS = [0]*256
def _w(a,b,v):
    for k in range(a,b+1): WIDTHS[k]=v
_w(0x00,0xff,1)
# singletons / explicit
for k,v in {0x02:2,0x03:3,0x05:2,0x06:3,0x08:2,0x09:3,
            0x13:2,0x14:3,0x15:2,0x16:2,0x17:3,0x18:5,0x19:2,0x1a:2,0x1b:3,0x1c:2,0x1f:2,
            0x20:2,0x22:2,0x23:2,0x24:3,0x25:3,0x26:3,0x29:2,0x2a:3,0x2b:3,0x2c:3,
            0x2d:2,0x2e:2,0x2f:2,0x30:2,0x31:2,0x32:2,0x33:2,0x34:2,0x35:2,0x36:2,0x37:2,
            0x38:2,0x39:2,0x3a:2,0x3b:2,0x3c:2,0x3d:2}.items():
    WIDTHS[k]=v
_w(0x44,0x6d,2)   # aget/aput, iget/iput, sget/sput (22c/21c)
_w(0x6e,0x72,3)   # invoke-kind (35c)
_w(0x74,0x78,3)   # invoke-kind/range (3rc)
_w(0x90,0xaf,2)   # binop (23x)
_w(0xd0,0xd7,2)   # binop/lit16 (22s)
_w(0xd8,0xe2,2)   # binop/lit8 (22b)
# ODEX quick/volatile region
for k,v in {0xe3:2,0xe4:2,0xe5:2,0xe6:2,0xe7:2,0xe8:2,0xe9:2,0xea:2,0xeb:2,0xed:2,
            0xee:3,0xef:3,0xf0:3,0xf2:2,0xf3:2,0xf4:2,0xf5:2,0xf6:2,0xf7:2,
            0xf8:3,0xf9:3,0xfa:3,0xfb:3,0xfc:2,0xfd:2,0xfe:2}.items():
    WIDTHS[k]=v

def uleb(d, o):
    res = 0; shift = 0
    while True:
        b = d[o]; o += 1
        res |= (b & 0x7f) << shift
        if not (b & 0x80): break
        shift += 7
    return res, o

class Dex:
    def __init__(self, path):
        raw = open(path,'rb').read()
        if raw[:4] == b'dey\n':            # ODEX wrapper
            dex_off = u4(raw, 8)
            dex_len = u4(raw, 12)
            d = raw[dex_off:dex_off+dex_len]
        else:
            d = raw
        self.d = d
        self.str_size = u4(d,56);  self.str_off = u4(d,60)
        self.type_size= u4(d,64);  self.type_off= u4(d,68)
        self.proto_size=u4(d,72);  self.proto_off=u4(d,76)
        self.field_size=u4(d,80);  self.field_off=u4(d,84)
        self.meth_size= u4(d,88);  self.meth_off= u4(d,92)
        self.cls_size = u4(d,96);  self.cls_off = u4(d,100)
        self._scache = {}

    def string(self, idx):
        if idx in self._scache: return self._scache[idx]
        off = u4(self.d, self.str_off + idx*4)
        n, off = uleb(self.d, off)           # utf16 units (ignored)
        end = self.d.index(b'\x00', off)
        s = self.d[off:end].decode('utf-8','replace')
        self._scache[idx] = s
        return s

    def type_desc(self, tidx):
        return self.string(u4(self.d, self.type_off + tidx*4))

    def field(self, fidx):
        o = self.field_off + fidx*8
        cls = u2(self.d,o); typ = u2(self.d,o+2); name = u4(self.d,o+4)
        return self.type_desc(cls), self.type_desc(typ), self.string(name)

    def proto_params(self, pidx):
        o = self.proto_off + pidx*12
        ret = self.type_desc(u4(self.d,o+4))
        poff = u4(self.d,o+8)
        params = []
        if poff:
            sz = u4(self.d, poff)
            for i in range(sz):
                params.append(self.type_desc(u2(self.d, poff+4+i*2)))
        return params, ret

    def method(self, midx):
        o = self.meth_off + midx*8
        cls = u2(self.d,o); proto = u2(self.d,o+2); name = u4(self.d,o+4)
        params, ret = self.proto_params(proto)
        return self.type_desc(cls), self.string(name), params, ret

    def classes(self):
        for i in range(self.cls_size):
            o = self.cls_off + i*32
            cidx = u4(self.d,o)
            yield (self.type_desc(cidx), u4(self.d,o+24), u4(self.d,o+28))  # desc, class_data_off, static_values_off

    def find(self, pattern):
        rx = re.compile(pattern)
        return [c for c in self.classes() if rx.search(c[0])]

    def class_data_fields_methods(self, class_data_off):
        if not class_data_off: return [],[]
        o = class_data_off
        sf,o = uleb(self.d,o); inf,o = uleb(self.d,o); dm,o = uleb(self.d,o); vm,o = uleb(self.d,o)
        static_fields=[]; fidx=0
        for _ in range(sf):
            diff,o = uleb(self.d,o); acc,o = uleb(self.d,o); fidx += diff
            static_fields.append(fidx)
        # skip instance fields
        ifidx=0
        for _ in range(inf):
            diff,o=uleb(self.d,o); acc,o=uleb(self.d,o)
        methods=[]; midx=0          # (method_idx, code_off)
        for _ in range(dm):
            diff,o=uleb(self.d,o); acc,o=uleb(self.d,o); code,o=uleb(self.d,o); midx+=diff
            methods.append((midx,code))
        midx=0
        for _ in range(vm):
            diff,o=uleb(self.d,o); acc,o=uleb(self.d,o); code,o=uleb(self.d,o); midx+=diff
            methods.append((midx,code))
        return static_fields, [m for (m,c) in methods], methods

    def encoded_value(self, o):
        arg_type = self.d[o]; o+=1
        vt = arg_type & 0x1f; sz = (arg_type >> 5) + 1
        def rd(signed):
            nonlocal o
            b = self.d[o:o+sz]; o += sz
            v = int.from_bytes(b,'little',signed=signed)
            return v
        if vt == 0x00: return ('byte', rd(True)), o
        if vt == 0x02: return ('short', rd(True)), o
        if vt == 0x03: return ('char', rd(False)), o
        if vt == 0x04: return ('int', rd(True)), o
        if vt == 0x06: return ('long', rd(True)), o
        if vt == 0x10: return ('float', rd(False)), o
        if vt == 0x11: return ('double', rd(False)), o
        if vt == 0x17: return ('string', rd(False)), o
        if vt == 0x18: return ('type', rd(False)), o
        if vt == 0x19 or vt==0x1a or vt==0x1b: return ('ref', rd(False)), o
        if vt == 0x1c:   # array
            n,o = uleb(self.d,o); vals=[]
            for _ in range(n):
                v,o = self.encoded_value(o); vals.append(v)
            return ('array', vals), o
        if vt == 0x1d:   # annotation - skip crudely
            return ('annotation', None), o
        if vt == 0x1e: return ('null', None), o
        if vt == 0x1f: return ('bool', (arg_type>>5)&1), o
        return ('?%02x'%vt, None), o

    def static_values(self, static_values_off):
        if not static_values_off: return []
        o = static_values_off
        n,o = uleb(self.d,o)
        out=[]
        for _ in range(n):
            v,o = self.encoded_value(o); out.append(v)
        return out

    def transactions(self, desc):
        for d2, cdo, svo in self.classes():
            if d2 != desc: continue
            sfields, _, _ = self.class_data_fields_methods(cdo)
            vals = self.static_values(svo)
            res={}
            for i, fidx in enumerate(sfields):
                _, ftype, fname = self.field(fidx)
                if fname.startswith('TRANSACTION_') and i < len(vals):
                    res[fname] = vals[i][1]
            return res
        return None

    def methods_named(self, desc, namesub):
        out=[]
        for d2, cdo, svo in self.classes():
            if d2 != desc: continue
            _, methods, _ = self.class_data_fields_methods(cdo)
            for midx in methods:
                mcls, mname, params, ret = self.method(midx)
                if namesub.lower() in mname.lower():
                    out.append((mname, params, ret))
        return out

    def disasm(self, desc, method_name):
        """Walk a method's bytecode, print invoke/sget/sput/const targets."""
        for d2, cdo, svo in self.classes():
            if d2 != desc: continue
            _, _, mlist = self.class_data_fields_methods(cdo)
            for midx, code_off in mlist:
                mcls, mname, params, ret = self.method(midx)
                if mname != method_name: continue
                if not code_off:
                    print("   (no code: abstract/native)"); continue
                self._walk(code_off, mcls, mname, params, ret)
            return

    def _walk(self, code_off, mcls, mname, params, ret):
        d = self.d
        insns_size = u4(d, code_off + 12)
        base = code_off + 16
        print("   --- %s.%s(%s)->%s  [%d units] ---" % (mcls, mname, ",".join(params), ret, insns_size))
        i = 0
        while i < insns_size:
            off = base + i*2
            op = d[off]
            unit0 = u2(d, off)
            # payloads
            if unit0 == 0x0100:
                sz = u2(d, off+2); i += (sz*2)+4; continue
            if unit0 == 0x0200:
                sz = u2(d, off+2); i += (sz*4)+2; continue
            if unit0 == 0x0300:
                ew = u2(d, off+2); sz = u4(d, off+4)
                i += ((sz*ew + 1)//2) + 4; continue
            w = WIDTHS[op]
            if op in (0x6e,0x6f,0x70,0x71,0x72,0x74,0x75,0x76,0x77,0x78):   # invoke* (real method ref)
                midx = u2(d, off+2)
                try:
                    c,n,p,r = self.method(midx)
                    kind = {0x6e:'virtual',0x6f:'super',0x70:'direct',0x71:'static',0x72:'interface',
                            0x74:'virtual/range',0x75:'super/range',0x76:'direct/range',0x77:'static/range',0x78:'interface/range'}[op]
                    print("     invoke-%s  %s.%s(%s)->%s" % (kind, c, n, ",".join(p), r))
                except Exception:
                    pass
            elif op in (0x60,0x61,0x62,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x6b,0x6c,0x6d):  # sget/sput
                fidx = u2(d, off+2)
                try:
                    fc,ft,fn = self.field(fidx)
                    print("     sfield     %s->%s" % (fc, fn))
                except Exception:
                    pass
            elif op == 0x13:   # const/16
                print("     const/16   v%d = %d" % (d[off+1], struct.unpack_from('<h', d, off+2)[0]))
            elif op == 0x12:   # const/4
                b = d[off+1]; val = (b>>4); val = val-16 if val>7 else val
                print("     const/4    v%d = %d" % (b & 0xf, val))
            elif op == 0x14:   # const
                print("     const      v%d = %d" % (d[off+1], u4(d, off+2)))
            elif op == 0x1a:   # const-string
                sidx = u2(d, off+2)
                try: print("     const-str  \"%s\"" % self.string(sidx))
                except Exception: pass
            elif op == 0x1b:   # const-string/jumbo
                sidx = u4(d, off+2)
                try: print("     const-str  \"%s\"" % self.string(sidx))
                except Exception: pass
            i += w
        print("   --- end (walk %s) ---" % ("aligned" if i==insns_size else "MISALIGNED@%d/%d"%(i,insns_size)))

def main():
    if sys.argv[1:] and sys.argv[1] == '--disasm':
        # --disasm <file> <ClassDescriptor> <method> [<file2> ...]
        _, _, f, cls, meth = sys.argv[:5]
        for ff in [f] + sys.argv[5:]:
            try: dx = Dex(ff)
            except Exception: continue
            if dx.find(re.escape(cls.strip('L;').split('/')[-1])):
                print("## %s" % ff.split('/')[-1])
                dx.disasm(cls, meth)
        return
    files = sys.argv[1:]
    targets = ['IBCMService','IUSMService','IDATCService','IHscanMicomService',
               'IVehicleOptionService','IHEVService','BCMCanManager','ClimateManager']
    methodsub = ['ChargeLockDoor','ChargingDoor','SWRC','SteeringWheel','WheelHeat','ChargeDoor']
    for f in files:
        try: dx = Dex(f)
        except Exception as e:
            print("## %s  ERROR %s"%(f,e)); continue
        hits=[]
        for t in targets:
            for desc, cdo, svo in dx.find(re.escape(t)):
                hits.append(desc)
        if not hits: continue
        print("\n################ %s ################"%f.split('/')[-1])
        seen=set()
        for desc in hits:
            if desc in seen: continue
            seen.add(desc)
            tx = dx.transactions(desc)
            print("\n=== %s ==="%desc)
            if tx:
                for k in sorted(tx, key=lambda x: tx[x] if isinstance(tx[x],int) else 0):
                    print("   %-45s = %s"%(k, tx[k]))
            # method signatures of interest
            for ms in methodsub:
                for mname,params,ret in dx.methods_named(desc, ms):
                    print("   method %s(%s) -> %s"%(mname, ",".join(params), ret))

if __name__=='__main__':
    main()
