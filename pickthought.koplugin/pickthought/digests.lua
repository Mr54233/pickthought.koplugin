local bit = require("bit")
local D = {}
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, ror = bit.lshift, bit.rshift, bit.rol, bit.ror
local function u32(x) return band(x, 0xffffffff) end
local function plus(...)
    local v = 0
    for i=1,select("#", ...) do v = u32(v + select(i, ...)) end
    return v
end
local function le32(s,p)
    local a,b,c,d=s:byte(p,p+3); return bor(a,lshift(b,8),lshift(c,16),lshift(d,24))
end
local function be32(s,p)
    local a,b,c,d=s:byte(p,p+3); return bor(lshift(a,24),lshift(b,16),lshift(c,8),d)
end
local function lehex(x)
    return string.format("%02x%02x%02x%02x", band(x,255), band(rshift(x,8),255), band(rshift(x,16),255), band(rshift(x,24),255))
end
local function behex(x)
    return string.format("%02x%02x%02x%02x", band(rshift(x,24),255), band(rshift(x,16),255), band(rshift(x,8),255), band(x,255))
end
local S={7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21}
local K={}
for i=1,64 do K[i]=math.floor(math.abs(math.sin(i))*4294967296) end
function D.md5(input)
    local s=tostring(input or ""); local bits=#s*8; local pad=(56-(#s+1)%64)%64
    s=s..string.char(128)..string.rep("\0",pad)..string.char(band(bits,255),band(rshift(bits,8),255),band(rshift(bits,16),255),band(rshift(bits,24),255),0,0,0,0)
    local A,B,C,E=0x67452301,0xefcdab89,0x98badcfe,0x10325476
    for pos=1,#s,64 do
        local m={}; for j=0,15 do m[j]=le32(s,pos+j*4) end
        local a,b,c,d=A,B,C,E
        for j=0,63 do
            local f,g
            if j<16 then f=bor(band(b,c),band(bnot(b),d)); g=j
            elseif j<32 then f=bor(band(d,b),band(bnot(d),c)); g=(5*j+1)%16
            elseif j<48 then f=bxor(b,c,d); g=(3*j+5)%16
            else f=bxor(c,bor(b,bnot(d))); g=(7*j)%16 end
            a,d,c,b=d,c,b,plus(b,rol(plus(a,f,K[j+1],m[g]),S[j+1]))
        end
        A,B,C,E=plus(A,a),plus(B,b),plus(C,c),plus(E,d)
    end
    return lehex(A)..lehex(B)..lehex(C)..lehex(E)
end
local H={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
function D.sha256(input)
    local s=tostring(input or ""); local bits=#s*8; local pad=(56-(#s+1)%64)%64
    s=s..string.char(128)..string.rep("\0",pad)..string.char(0,0,0,0,band(rshift(bits,24),255),band(rshift(bits,16),255),band(rshift(bits,8),255),band(bits,255))
    local h={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
    for pos=1,#s,64 do
        local w={}; for j=0,15 do w[j]=be32(s,pos+j*4) end
        for j=16,63 do
            local x=bxor(ror(w[j-15],7),ror(w[j-15],18),rshift(w[j-15],3))
            local y=bxor(ror(w[j-2],17),ror(w[j-2],19),rshift(w[j-2],10))
            w[j]=plus(w[j-16],x,w[j-7],y)
        end
        local a,b,c,d,e,f,g,q=h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
        for j=0,63 do
            local s1=bxor(ror(e,6),ror(e,11),ror(e,25)); local ch=bxor(band(e,f),band(bnot(e),g))
            local t1=plus(q,s1,ch,H[j+1],w[j]); local s0=bxor(ror(a,2),ror(a,13),ror(a,22))
            local maj=bxor(band(a,b),band(a,c),band(b,c)); local t2=plus(s0,maj)
            q,g,f,e,d,c,b,a=g,f,e,plus(d,t1),c,b,a,plus(t1,t2)
        end
        h[1],h[2],h[3],h[4]=plus(h[1],a),plus(h[2],b),plus(h[3],c),plus(h[4],d)
        h[5],h[6],h[7],h[8]=plus(h[5],e),plus(h[6],f),plus(h[7],g),plus(h[8],q)
    end
    local out={}; for i=1,8 do out[i]=behex(h[i]) end; return table.concat(out)
end
return D
