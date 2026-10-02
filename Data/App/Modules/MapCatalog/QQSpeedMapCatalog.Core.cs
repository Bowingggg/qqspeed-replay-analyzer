using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Security.Cryptography;

public sealed class CatalogNode {
    public string Vfs;
    public string VfsPath;
    public long IndexOffset;
    public long VirtualAddress;
    public string Name;
    public string FullPath;
    public uint OriginalSize;
    public uint StoredSize;
    public uint Type;
    public uint DataOffset;
    public uint Parent;
}

public sealed class DescriptorInfo {
    public int MapId;
    public string Vfs;
    public string FullPath;
    public string Md5;
    public string MapName;
    public bool Parsed;
    public string ParseStatus;
}

// `Map\Common Map\MapNN\LapDistanceFile.luc` is the resource's own per-map record:
// it declares `mapId` (the GAME-side MapID namespace, the same one the room selection
// table `uires\mapsel\maps.luc` stores as `mapid`) and `mapName` (the maintained display
// name). `map_desc.luc` lives in the same folder but its `map_name` is a scene-descriptor
// label that the client does not keep in step (see docs/decisions/0014), so the name here
// is the authoritative one and the folder number is *not* assumed to be mapid - 100.
public sealed class LapDistanceInfo {
    public int MapId;
    public string Vfs;
    public string FullPath;
    public string Md5;
    public string MapName;
    public long? DeclaredGameMapId;
    public bool Parsed;
    public string ParseStatus;
}

public static class QQMapCatalogCore {
    static readonly byte[] Alphabet=Encoding.ASCII.GetBytes("QSPEDIKJHMNATOGC");
    static readonly int[] S2N=BuildReverse();

    static int[] BuildReverse() {
        int[] r=Enumerable.Repeat(-1,256).ToArray();
        for(int i=0;i<Alphabet.Length;i++) r[Alphabet[i]]=i;
        return r;
    }

    static uint U32(byte[] b,int o){return BitConverter.ToUInt32(b,o);}

    static byte[] ReadExact(Stream s,int n) {
        byte[] b=new byte[n];
        int got=0;
        while(got<n) {
            int k=s.Read(b,got,n-got);
            if(k<=0)throw new EndOfStreamException();
            got+=k;
        }
        return b;
    }

    static byte[] DecodeIndex(byte[] enc) {
        if((enc.Length&1)!=0)throw new InvalidDataException("odd index payload");
        byte[] d=new byte[enc.Length/2];
        for(int i=0;i<d.Length;i++) {
            int hi=S2N[enc[i*2]],lo=S2N[enc[i*2+1]];
            if(hi<0||lo<0)throw new InvalidDataException("unknown VFS index symbol");
            d[i]=(byte)((hi<<4)|lo);
        }
        return d;
    }

    static string AsciiName(byte[] b,int o,int n) {
        var sb=new StringBuilder(n);
        for(int i=0;i<n;i++) {
            byte x=b[o+i];
            sb.Append(x>=32&&x<127?(char)x:'?');
        }
        return sb.ToString();
    }

    public static CatalogNode[] ParseAllMapNodes(string gamePath) {
        var output=new List<CatalogNode>();

        foreach(string vfsPath in Directory.GetFiles(gamePath,"*.vfs",SearchOption.TopDirectoryOnly)) {
            try {
                using(var fs=new FileStream(vfsPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
                    byte[] hdr=ReadExact(fs,64);
                    if(Encoding.ASCII.GetString(hdr,0,4)!="vfs ")continue;
                    long idx=BitConverter.ToUInt32(hdr,0x18);
                    if(idx<512||idx>=fs.Length)continue;

                    fs.Seek(idx,SeekOrigin.Begin);
                    uint count=BitConverter.ToUInt32(ReadExact(fs,4),0);
                    long virtualAddress=idx+4;
                    var local=new List<CatalogNode>();

                    for(int ei=0;ei<count;ei++) {
                        byte[] bh=ReadExact(fs,8);
                        uint encLen=BitConverter.ToUInt32(bh,0);
                        uint decLen=BitConverter.ToUInt32(bh,4);
                        if(encLen!=decLen*2||decLen<60||encLen>2*1024*1024)
                            throw new InvalidDataException("bad VFS index block");

                        byte[] d=DecodeIndex(ReadExact(fs,(int)encLen));
                        if(U32(d,0)!=0x68656164||U32(d,d.Length-4)!=0x7461696c)
                            throw new InvalidDataException("bad VFS index record markers");

                        uint nameLen=U32(d,4);
                        if(nameLen+60!=d.Length)throw new InvalidDataException("bad VFS record length");
                        string name=AsciiName(d,8,(int)nameLen);
                        int m=8+(int)nameLen;

                        local.Add(new CatalogNode{
                            Vfs=Path.GetFileName(vfsPath),
                            VfsPath=vfsPath,
                            IndexOffset=idx,
                            VirtualAddress=virtualAddress,
                            Name=name,
                            OriginalSize=U32(d,m+0),
                            StoredSize=U32(d,m+4),
                            Type=U32(d,m+8),
                            DataOffset=U32(d,m+12),
                            Parent=U32(d,m+16),
                            FullPath=""
                        });
                        virtualAddress+=decLen;
                    }

                    var byAddr=local.ToDictionary(x=>x.VirtualAddress,x=>x);
                    var cache=new Dictionary<long,string>();

                    Func<CatalogNode,HashSet<long>,string> build=null;
                    build=(n,stack)=>{
                        string cached;
                        if(cache.TryGetValue(n.VirtualAddress,out cached))return cached;
                        if(stack.Contains(n.VirtualAddress))throw new InvalidDataException("parent cycle");
                        stack.Add(n.VirtualAddress);

                        string path;
                        if(n.Parent==0)path=n.Name;
                        else {
                            CatalogNode par;
                            if(!byAddr.TryGetValue((long)n.Parent,out par))
                                throw new InvalidDataException("parent pointer not found");
                            string pp=build(par,stack);
                            path=String.IsNullOrEmpty(pp)?n.Name:(pp+"\\"+n.Name);
                        }

                        stack.Remove(n.VirtualAddress);
                        cache[n.VirtualAddress]=path;
                        return path;
                    };

                    foreach(var n in local) {
                        try { n.FullPath=build(n,new HashSet<long>()); }
                        catch { n.FullPath=""; }

                        if(!String.IsNullOrEmpty(n.FullPath) &&
                           n.FullPath.StartsWith(@"Map\Common Map\Map",StringComparison.OrdinalIgnoreCase)) {
                            output.Add(n);
                        }
                    }
                }
            } catch {
                // One bad archive must not prevent cataloging every other VFS.
            }
        }

        return output.ToArray();
    }


    // Full VFS index enumeration for diagnostics that need resources outside
    // Map\Common Map\MapNN (for example room/map-selection UI scripts).
    // Existing ParseAllMapNodes remains unchanged so production map-catalog
    // behavior is not widened accidentally.
    public static CatalogNode[] ParseAllNodes(string gamePath) {
        var output=new List<CatalogNode>();

        foreach(string vfsPath in Directory.GetFiles(gamePath,"*.vfs",SearchOption.TopDirectoryOnly)) {
            try {
                using(var fs=new FileStream(vfsPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
                    byte[] hdr=ReadExact(fs,64);
                    if(Encoding.ASCII.GetString(hdr,0,4)!="vfs ")continue;
                    long idx=BitConverter.ToUInt32(hdr,0x18);
                    if(idx<512||idx>=fs.Length)continue;

                    fs.Seek(idx,SeekOrigin.Begin);
                    uint count=BitConverter.ToUInt32(ReadExact(fs,4),0);
                    long virtualAddress=idx+4;
                    var local=new List<CatalogNode>();

                    for(int ei=0;ei<count;ei++) {
                        byte[] bh=ReadExact(fs,8);
                        uint encLen=BitConverter.ToUInt32(bh,0);
                        uint decLen=BitConverter.ToUInt32(bh,4);
                        if(encLen!=decLen*2||decLen<60||encLen>2*1024*1024)
                            throw new InvalidDataException("bad VFS index block");

                        byte[] d=DecodeIndex(ReadExact(fs,(int)encLen));
                        if(U32(d,0)!=0x68656164||U32(d,d.Length-4)!=0x7461696c)
                            throw new InvalidDataException("bad VFS index record markers");

                        uint nameLen=U32(d,4);
                        if(nameLen+60!=d.Length)throw new InvalidDataException("bad VFS record length");
                        string name=AsciiName(d,8,(int)nameLen);
                        int m=8+(int)nameLen;

                        local.Add(new CatalogNode{
                            Vfs=Path.GetFileName(vfsPath),
                            VfsPath=vfsPath,
                            IndexOffset=idx,
                            VirtualAddress=virtualAddress,
                            Name=name,
                            OriginalSize=U32(d,m+0),
                            StoredSize=U32(d,m+4),
                            Type=U32(d,m+8),
                            DataOffset=U32(d,m+12),
                            Parent=U32(d,m+16),
                            FullPath=""
                        });
                        virtualAddress+=decLen;
                    }

                    var byAddr=local.ToDictionary(x=>x.VirtualAddress,x=>x);
                    var cache=new Dictionary<long,string>();

                    Func<CatalogNode,HashSet<long>,string> build=null;
                    build=(n,stack)=>{
                        string cached;
                        if(cache.TryGetValue(n.VirtualAddress,out cached))return cached;
                        if(stack.Contains(n.VirtualAddress))throw new InvalidDataException("parent cycle");
                        stack.Add(n.VirtualAddress);

                        string path;
                        if(n.Parent==0)path=n.Name;
                        else {
                            CatalogNode par;
                            if(!byAddr.TryGetValue((long)n.Parent,out par))
                                throw new InvalidDataException("parent pointer not found");
                            string pp=build(par,stack);
                            path=String.IsNullOrEmpty(pp)?n.Name:(pp+"\\"+n.Name);
                        }

                        stack.Remove(n.VirtualAddress);
                        cache[n.VirtualAddress]=path;
                        return path;
                    };

                    foreach(var n in local) {
                        try { n.FullPath=build(n,new HashSet<long>()); }
                        catch { n.FullPath=""; }
                        if(!String.IsNullOrEmpty(n.FullPath))output.Add(n);
                    }
                }
            } catch {
                // Diagnostic enumeration must tolerate one malformed archive.
            }
        }

        return output.ToArray();
    }

    static bool ThumbImageName(string name) {
        string lo=(name??"").ToLowerInvariant();
        return lo.EndsWith(".png")||lo.EndsWith(".jpg")||lo.EndsWith(".jpeg")||lo.EndsWith(".bmp")||lo.EndsWith(".gif")||lo.EndsWith(".tga")||lo.EndsWith(".dds")||lo.EndsWith(".tex")||lo.EndsWith(".texture");
    }

    static bool ThumbConfigName(string name) {
        string lo=(name??"").ToLowerInvariant();
        return lo.EndsWith(".xml")||lo.EndsWith(".txt")||lo.EndsWith(".ini")||lo.EndsWith(".cfg")||lo.EndsWith(".json")||lo.EndsWith(".lua")||lo.EndsWith(".luc")||lo.EndsWith(".tab")||lo.EndsWith(".csv")||lo.EndsWith(".dat");
    }

    static bool ThumbKeywordName(string name,int mapId) {
        string lo=(name??"").ToLowerInvariant();
        string id=mapId.ToString();
        return lo.Contains("minimap")||lo.Contains("mini_map")||lo.Contains("mini-map")||
               lo.Contains("thumb")||lo.Contains("preview")||lo.Contains("mapicon")||lo.Contains("map_icon")||
               lo.Contains("track")||lo.Contains("course")||lo.Contains("race")||lo.Contains("route")||
               lo.Contains("maplist")||lo.Contains("map_list")||lo.Contains("map"+id)||lo.Contains("map0"+id);
    }

    public static CatalogNode[] ParseThumbnailProbeNodesFromVfs(string vfsPath,int mapId) {
        var output=new List<CatalogNode>();
        if(String.IsNullOrWhiteSpace(vfsPath)||!File.Exists(vfsPath))return output.ToArray();
        try {
            using(var fs=new FileStream(vfsPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
                byte[] hdr=ReadExact(fs,64);
                if(Encoding.ASCII.GetString(hdr,0,4)!="vfs ")return output.ToArray();
                long idx=BitConverter.ToUInt32(hdr,0x18);
                if(idx<512||idx>=fs.Length)return output.ToArray();

                fs.Seek(idx,SeekOrigin.Begin);
                uint count=BitConverter.ToUInt32(ReadExact(fs,4),0);
                long virtualAddress=idx+4;
                var local=new List<CatalogNode>();

                for(int ei=0;ei<count;ei++) {
                    byte[] bh=ReadExact(fs,8);
                    uint encLen=BitConverter.ToUInt32(bh,0);
                    uint decLen=BitConverter.ToUInt32(bh,4);
                    if(encLen!=decLen*2||decLen<60||encLen>2*1024*1024)
                        throw new InvalidDataException("bad VFS index block");

                    byte[] d=DecodeIndex(ReadExact(fs,(int)encLen));
                    if(U32(d,0)!=0x68656164||U32(d,d.Length-4)!=0x7461696c)
                        throw new InvalidDataException("bad VFS index record markers");

                    uint nameLen=U32(d,4);
                    if(nameLen+60!=d.Length)throw new InvalidDataException("bad VFS record length");
                    string name=AsciiName(d,8,(int)nameLen);
                    int m=8+(int)nameLen;

                    local.Add(new CatalogNode{
                        Vfs=Path.GetFileName(vfsPath),
                        VfsPath=vfsPath,
                        IndexOffset=idx,
                        VirtualAddress=virtualAddress,
                        Name=name,
                        OriginalSize=U32(d,m+0),
                        StoredSize=U32(d,m+4),
                        Type=U32(d,m+8),
                        DataOffset=U32(d,m+12),
                        Parent=U32(d,m+16),
                        FullPath=""
                    });
                    virtualAddress+=decLen;
                }

                var byAddr=local.ToDictionary(x=>x.VirtualAddress,x=>x);
                var children=new Dictionary<uint,List<CatalogNode>>();
                foreach(var n in local) {
                    List<CatalogNode> list;
                    if(!children.TryGetValue(n.Parent,out list)){list=new List<CatalogNode>();children[n.Parent]=list;}
                    list.Add(n);
                }
                var cache=new Dictionary<long,string>();
                Func<CatalogNode,HashSet<long>,string> build=null;
                build=(n,stack)=>{
                    string cached;
                    if(cache.TryGetValue(n.VirtualAddress,out cached))return cached;
                    if(stack.Contains(n.VirtualAddress))throw new InvalidDataException("parent cycle");
                    stack.Add(n.VirtualAddress);
                    string path;
                    if(n.Parent==0)path=n.Name;
                    else {
                        CatalogNode par;
                        if(!byAddr.TryGetValue((long)n.Parent,out par))throw new InvalidDataException("parent pointer not found");
                        string pp=build(par,stack);
                        path=String.IsNullOrEmpty(pp)?n.Name:(pp+"\\"+n.Name);
                    }
                    stack.Remove(n.VirtualAddress);
                    cache[n.VirtualAddress]=path;
                    return path;
                };

                var added=new HashSet<long>();
                Action<CatalogNode> add=(n)=>{
                    if(!added.Add(n.VirtualAddress))return;
                    try { n.FullPath=build(n,new HashSet<long>()); } catch { n.FullPath=""; }
                    if(!String.IsNullOrEmpty(n.FullPath))output.Add(n);
                };

                // Fast path: locate only the requested Map<ID> folder, then walk its descendants.
                string targetFolder="Map"+mapId.ToString();
                string targetPath=@"Map\Common Map\"+targetFolder;
                foreach(var root in local) {
                    if(!String.Equals(root.Name,targetFolder,StringComparison.OrdinalIgnoreCase))continue;
                    string rp="";try{rp=build(root,new HashSet<long>());}catch{}
                    if(!String.Equals(rp,targetPath,StringComparison.OrdinalIgnoreCase))continue;
                    var q=new Queue<CatalogNode>();
                    List<CatalogNode> first;
                    if(children.TryGetValue((uint)root.VirtualAddress,out first))foreach(var c in first)q.Enqueue(c);
                    while(q.Count>0) {
                        var n=q.Dequeue();add(n);
                        List<CatalogNode> cc;
                        if(children.TryGetValue((uint)n.VirtualAddress,out cc))foreach(var c in cc)q.Enqueue(c);
                    }
                }

                // Global fallback: keep only strongly named thumbnail / map-index resources.
                // Do not collect every image from every VFS: it produces hundreds of thousands of candidates.
                foreach(var n in local) {
                    bool keyword=ThumbKeywordName(n.Name,mapId);
                    if(!keyword)continue;
                    bool image=ThumbImageName(n.Name);
                    bool cfg=ThumbConfigName(n.Name) && n.OriginalSize>0 && n.OriginalSize<=2097152;
                    if(image || cfg)add(n);
                }
            }
        } catch {
            // One bad archive must not prevent probing every other VFS.
        }
        return output.ToArray();
    }

    public static CatalogNode[] ParseThumbnailProbeNodes(string gamePath,int mapId) {
        var output=new List<CatalogNode>();
        foreach(string vfsPath in Directory.GetFiles(gamePath,"*.vfs",SearchOption.TopDirectoryOnly))
            output.AddRange(ParseThumbnailProbeNodesFromVfs(vfsPath,mapId));
        return output.ToArray();
    }

    public static byte[] ExtractDecoded(CatalogNode n) {
        if(n==null||n.Type!=1||n.StoredSize==0||n.DataOffset==0)return null;

        var blocks=new List<byte[]>();
        long remaining=n.StoredSize;
        long current=n.DataOffset;
        var seen=new HashSet<long>();

        using(var fs=new FileStream(n.VfsPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
            while(remaining>0) {
                if(current<=0||current+16>n.IndexOffset||!seen.Add(current))return null;
                fs.Seek(current,SeekOrigin.Begin);
                byte[] hdr=ReadExact(fs,16);
                if(BitConverter.ToUInt32(hdr,0)!=0x68656164)return null;
                uint link=BitConverter.ToUInt32(hdr,8);
                uint payloadLen=BitConverter.ToUInt32(hdr,12);
                if(payloadLen==0||payloadLen>remaining||current+16L+payloadLen>n.IndexOffset)return null;
                blocks.Add(ReadExact(fs,(int)payloadLen));
                remaining-=payloadLen;
                if(remaining==0)break;
                if(link==0)return null;
                current=link;
            }
        }

        byte[] compressed;
        using(var ms=new MemoryStream()) {
            foreach(byte[] b in blocks)ms.Write(b,0,b.Length);
            compressed=ms.ToArray();
        }

        if(compressed.Length==n.OriginalSize)return compressed;

        if(compressed.Length>=6&&compressed[0]==0x78) {
            try {
                using(var src=new MemoryStream(compressed,2,compressed.Length-6,false))
                using(var ds=new DeflateStream(src,CompressionMode.Decompress))
                using(var dst=new MemoryStream()) {
                    ds.CopyTo(dst);
                    byte[] d=dst.ToArray();
                    if(d.Length==n.OriginalSize)return d;
                }
            } catch {}
        }

        try {
            using(var dst=new MemoryStream()) {
                foreach(byte[] b in blocks) {
                    if(b.Length<6||b[0]!=0x78)return null;
                    using(var src=new MemoryStream(b,2,b.Length-6,false))
                    using(var ds=new DeflateStream(src,CompressionMode.Decompress)) {
                        ds.CopyTo(dst);
                    }
                }
                byte[] d=dst.ToArray();
                if(d.Length==n.OriginalSize)return d;
            }
        } catch {}

        return null;
    }

    public static string Md5Hex(byte[] b) {
        if(b==null)return "";
        using(var m=MD5.Create())
            return BitConverter.ToString(m.ComputeHash(b)).Replace("-","").ToUpperInvariant();
    }

    sealed class LuaReader {
        public byte[] B;
        public int P;
        public LuaReader(byte[] b){B=b;P=0;}
        public byte[] Read(int n){
            if(n<0||P+n>B.Length)throw new EndOfStreamException();
            byte[] x=new byte[n];
            Buffer.BlockCopy(B,P,x,0,n);
            P+=n;return x;
        }
        public byte U8(){return Read(1)[0];}
        public uint U32(){return BitConverter.ToUInt32(Read(4),0);}
        public int I32(){return BitConverter.ToInt32(Read(4),0);}
        public long I64(){return BitConverter.ToInt64(Read(8),0);}
        public double F64(){return BitConverter.ToDouble(Read(8),0);}
        public ulong VarUInt(){
            ulong x=0;
            for(int i=0;i<10;i++) {
                byte b=U8();
                if(x>(UInt64.MaxValue>>7))throw new InvalidDataException("Lua varint overflow");
                x=(x<<7)|((ulong)b & 0x7FUL);
                if((b&0x80)!=0)return x;
            }
            throw new InvalidDataException("Lua varint too long");
        }
        public string Str(){
            uint n=U32();
            if(n==0)return null;
            if(n>Int32.MaxValue)throw new InvalidDataException("Lua string too large");
            byte[] x=Read((int)n);
            int len=x.Length;
            if(len>0&&x[len-1]==0)len--;
            return Encoding.GetEncoding(936).GetString(x,0,len);
        }
        public string Str54(){
            ulong n=VarUInt();
            if(n==0)return null;
            if(n>2147483648UL)throw new InvalidDataException("Lua 5.4 string too large");
            byte[] x=Read((int)n-1);
            // QQ Speed migrated the bytecode container to Lua 5.4, but the
            // string payloads in map_desc.luc remain CP936/GBK.  Decoding
            // as UTF-8 is unsafe because many valid two-byte GBK sequences
            // are also syntactically valid UTF-8 and silently become mojibake.
            return Encoding.GetEncoding(936).GetString(x);
        }
    }

    static object RK(object[] regs,object[] constants,int x) {
        if(x<250)return regs[x];
        int k=x-250;
        if(k<0||k>=constants.Length)return null;
        return constants[k];
    }

    static bool TryExtractMapNameLua50(byte[] lua,out string mapName,out string status) {
        mapName="";
        status="";
        try {
            var r=new LuaReader(lua);
            byte[] magic=r.Read(4);
            if(magic[0]!=0x1B||magic[1]!=(byte)'L'||magic[2]!=(byte)'u'||magic[3]!=(byte)'a')
                throw new InvalidDataException("not Lua bytecode");
            if(r.U8()!=0x50)throw new InvalidDataException("not Lua 5.0");
            if(r.U8()!=1)throw new InvalidDataException("unsupported Lua endianness");

            byte[] expected=new byte[]{4,4,4,6,8,9,9,8};
            for(int i=0;i<expected.Length;i++)
                if(r.U8()!=expected[i])throw new InvalidDataException("unexpected Lua header layout");

            r.F64();
            r.Str();
            r.I32();
            r.U8();r.U8();r.U8();
            int maxstack=r.U8();

            int nline=r.I32();
            if(nline<0||nline>10000000)throw new InvalidDataException("bad line table");
            for(int i=0;i<nline;i++)r.I32();

            int nloc=r.I32();
            if(nloc<0||nloc>1000000)throw new InvalidDataException("bad local table");
            for(int i=0;i<nloc;i++){r.Str();r.I32();r.I32();}

            int nuv=r.I32();
            if(nuv<0||nuv>1000000)throw new InvalidDataException("bad upvalue table");
            for(int i=0;i<nuv;i++)r.Str();

            int nk=r.I32();
            if(nk<0||nk>1000000)throw new InvalidDataException("bad constant table");
            object[] constants=new object[nk];
            for(int i=0;i<nk;i++) {
                byte t=r.U8();
                if(t==0)constants[i]=null;
                else if(t==3)constants[i]=r.F64();
                else if(t==4)constants[i]=r.Str();
                else throw new InvalidDataException("unsupported Lua constant type "+t);
            }

            int np=r.I32();
            if(np!=0)throw new InvalidDataException("nested Lua prototype not supported in map_desc");

            int nc=r.I32();
            if(nc<0||nc>10000000)throw new InvalidDataException("bad Lua code size");
            uint[] code=new uint[nc];
            for(int i=0;i<nc;i++)code[i]=r.U32();

            // Exact direct assignment: table["map_name"] = "..."
            for(int i=0;i<code.Length;i++) {
                uint ins=code[i];
                int op=(int)(ins&63);
                if(op!=9)continue;
                int C=(int)((ins>>6)&511);
                int B=(int)((ins>>15)&511);
                if(B<250||C<250)continue;
                int kb=B-250,kv=C-250;
                if(kb>=0&&kb<constants.Length&&kv>=0&&kv<constants.Length) {
                    string key=constants[kb] as string;
                    string val=constants[kv] as string;
                    if(String.Equals(key,"map_name",StringComparison.Ordinal)&&!String.IsNullOrWhiteSpace(val)) {
                        mapName=val;
                        status="exact SETTABLE constant";
                        return true;
                    }
                }
            }

            object[] regs=new object[Math.Max(300,maxstack+16)];
            var globals=new Dictionary<string,object>(StringComparer.Ordinal);

            for(int pc=0;pc<code.Length;pc++) {
                uint ins=code[pc];
                int op=(int)(ins&63);
                int C=(int)((ins>>6)&511);
                int B=(int)((ins>>15)&511);
                int A=(int)((ins>>24)&255);
                int Bx=(int)((ins>>6)&0x3ffff);

                switch(op) {
                    case 0: regs[A]=regs[B]; break;
                    case 1: regs[A]=(Bx>=0&&Bx<constants.Length)?constants[Bx]:null; break;
                    case 2: regs[A]=(B!=0); break;
                    case 3:
                        for(int j=A;j<=B&&j<regs.Length;j++)regs[j]=null;
                        break;
                    case 5: {
                        string k=(Bx>=0&&Bx<constants.Length)?constants[Bx] as string:null;
                        object v=null;if(k!=null)globals.TryGetValue(k,out v);regs[A]=v;break;
                    }
                    case 6: {
                        var t=regs[B] as Dictionary<object,object>;
                        object v=null;if(t!=null)t.TryGetValue(RK(regs,constants,C),out v);regs[A]=v;break;
                    }
                    case 7: {
                        string k=(Bx>=0&&Bx<constants.Length)?constants[Bx] as string:null;
                        if(k!=null)globals[k]=regs[A];break;
                    }
                    case 9: {
                        var t=regs[A] as Dictionary<object,object>;
                        if(t!=null)t[RK(regs,constants,B)]=RK(regs,constants,C);
                        break;
                    }
                    case 10: regs[A]=new Dictionary<object,object>(); break;
                    case 12: regs[A]=Convert.ToDouble(RK(regs,constants,B))+Convert.ToDouble(RK(regs,constants,C));break;
                    case 13: regs[A]=Convert.ToDouble(RK(regs,constants,B))-Convert.ToDouble(RK(regs,constants,C));break;
                    case 14: regs[A]=Convert.ToDouble(RK(regs,constants,B))*Convert.ToDouble(RK(regs,constants,C));break;
                    case 15: regs[A]=Convert.ToDouble(RK(regs,constants,B))/Convert.ToDouble(RK(regs,constants,C));break;
                    case 16: regs[A]=Math.Pow(Convert.ToDouble(RK(regs,constants,B)),Convert.ToDouble(RK(regs,constants,C)));break;
                    case 17: regs[A]=-Convert.ToDouble(regs[B]);break;
                    case 18: regs[A]=!(regs[B] is bool && (bool)regs[B]);break;
                    case 19: {
                        var sb=new StringBuilder();
                        for(int j=B;j<=C;j++)sb.Append(regs[j]==null?"":regs[j].ToString());
                        regs[A]=sb.ToString();break;
                    }
                    case 27: pc=code.Length; break;
                    case 31: {
                        var t=regs[A] as Dictionary<object,object>;
                        if(t!=null) {
                            int count=(Bx%32)+1;
                            int bas=Bx-(Bx%32);
                            for(int j=1;j<=count;j++)t[bas+j]=regs[A+j];
                        }
                        break;
                    }
                    default:
                        status="unsupported Lua opcode "+op;
                        pc=code.Length;
                        break;
                }
            }

            object descObj=null;
            if(globals.TryGetValue("map_desc",out descObj)) {
                var desc=descObj as Dictionary<object,object>;
                if(desc!=null) {
                    object value=null;
                    if(desc.TryGetValue("map_name",out value)&&value is string&&!String.IsNullOrWhiteSpace((string)value)) {
                        mapName=(string)value;
                        status="static Lua table";
                        return true;
                    }
                }
            }

            if(String.IsNullOrEmpty(status))status="map_name assignment not found";
            return false;
        } catch(Exception ex) {
            status=ex.GetType().Name+": "+ex.Message;
            return false;
        }
    }

    static object ReadLua54Constant(LuaReader r) {
        byte t=r.U8();
        if(t==0x00)return null;
        if(t==0x01)return false;
        if(t==0x11)return true;
        if(t==0x03)return r.I64();
        if(t==0x13)return r.F64();
        if(t==0x04||t==0x14)return r.Str54();
        throw new InvalidDataException("unsupported Lua 5.4 constant type "+t);
    }

    static bool ScanLua54PrototypeForField(LuaReader r,string fieldName,int depth,bool stringOnly,out object value,out string status) {
        value=null;
        status="";
        if(depth>64)throw new InvalidDataException("Lua 5.4 prototype nesting too deep");

        r.Str54(); // source (nullable; child may inherit parent source)
        r.VarUInt(); // line defined
        r.VarUInt(); // last line defined
        r.U8(); // num params
        r.U8(); // is_vararg / flags
        r.U8(); // max stack

        ulong nc64=r.VarUInt();
        if(nc64>10000000UL)throw new InvalidDataException("bad Lua 5.4 code size");
        int nc=(int)nc64;
        uint[] code=new uint[nc];
        for(int i=0;i<nc;i++)code[i]=r.U32();

        ulong nk64=r.VarUInt();
        if(nk64>1000000UL)throw new InvalidDataException("bad Lua 5.4 constant table");
        int nk=(int)nk64;
        object[] constants=new object[nk];
        for(int i=0;i<nk;i++)constants[i]=ReadLua54Constant(r);

        // Exact Lua 5.4 field writes. This covers both globals (_ENV via
        // SETTABUP) and ordinary table fields (SETFIELD).
        object[] regs=new object[256];
        for(int i=0;i<code.Length;i++) {
            uint ins=code[i];
            int op=(int)(ins&0x7FU);
            int A=(int)((ins>>7)&0xFFU);
            int k=(int)((ins>>15)&1U);
            int B=(int)((ins>>16)&0xFFU);
            int C=(int)((ins>>24)&0xFFU);

            if(op==0) { // MOVE
                if(A<regs.Length&&B<regs.Length)regs[A]=regs[B];
                continue;
            }
            if(op==3) { // LOADK
                int Bx=(int)((ins>>15)&0x1FFFFU);
                if(A<regs.Length&&Bx>=0&&Bx<constants.Length)regs[A]=constants[Bx];
                continue;
            }
            if(op==15||op==18) { // SETTABUP / SETFIELD
                if(B<0||B>=constants.Length)continue;
                string key=constants[B] as string;
                if(!String.Equals(key,fieldName,StringComparison.Ordinal))continue;
                object vv=null;
                if(k==1) {
                    if(C>=0&&C<constants.Length)vv=constants[C];
                } else if(C>=0&&C<regs.Length)vv=regs[C];
                if(AcceptFieldValue(vv,stringOnly)) {
                    value=vv;
                    status=(op==15?"exact Lua 5.4 SETTABUP":"exact Lua 5.4 SETFIELD")+
                           (k==1?" constant":" register")+"; prototype depth "+depth;
                    return true;
                }
            }
        }

        // Upvalue descriptors: instack, idx, kind.
        ulong nuv64=r.VarUInt();
        if(nuv64>1000000UL)throw new InvalidDataException("bad Lua 5.4 upvalue table");
        int nuv=(int)nuv64;
        for(int i=0;i<nuv;i++){r.U8();r.U8();r.U8();}

        // Child prototypes are full Proto records. LapDistanceFile.luc uses
        // nested prototypes on newer client data, so field assignments can
        // live below the main chunk.
        ulong np64=r.VarUInt();
        if(np64>1000000UL)throw new InvalidDataException("bad Lua 5.4 prototype table");
        int np=(int)np64;
        for(int i=0;i<np;i++) {
            object childValue; string childStatus;
            if(ScanLua54PrototypeForField(r,fieldName,depth+1,stringOnly,out childValue,out childStatus)) {
                value=childValue;
                status=childStatus;
                return true;
            }
        }

        // Debug tables must be consumed so sibling prototypes stay aligned.
        ulong nline64=r.VarUInt();
        if(nline64>10000000UL)throw new InvalidDataException("bad Lua 5.4 lineinfo table");
        r.Read((int)nline64);

        ulong nabs64=r.VarUInt();
        if(nabs64>1000000UL)throw new InvalidDataException("bad Lua 5.4 abslineinfo table");
        for(ulong i=0;i<nabs64;i++){r.VarUInt();r.VarUInt();}

        ulong nloc64=r.VarUInt();
        if(nloc64>1000000UL)throw new InvalidDataException("bad Lua 5.4 local table");
        for(ulong i=0;i<nloc64;i++){r.Str54();r.VarUInt();r.VarUInt();}

        ulong nupnames64=r.VarUInt();
        if(nupnames64>1000000UL)throw new InvalidDataException("bad Lua 5.4 upvalue-name table");
        for(ulong i=0;i<nupnames64;i++)r.Str54();

        status="Lua 5.4 field assignment not found";
        return false;
    }

    static bool ScanLua54PrototypeForStringField(LuaReader r,string fieldName,int depth,out string value,out string status) {
        object raw;
        bool ok=ScanLua54PrototypeForField(r,fieldName,depth,true,out raw,out status);
        value=(ok&&raw is string)?(string)raw:"";
        return ok;
    }

    // A field assignment is accepted when its value has an acceptable shape. `stringOnly` is the
    // historical behavior (non-empty string); otherwise numeric constants are accepted too, which is
    // what the per-map `LapDistanceFile.luc` `mapId` field needs.
    static bool AcceptFieldValue(object v,bool stringOnly) {
        if(v==null)return false;
        if(v is string)return !String.IsNullOrWhiteSpace((string)v);
        if(stringOnly)return false;
        return v is double||v is long||v is int;
    }

    static bool TryExtractFieldLua50(byte[] lua,string fieldName,bool stringOnly,out object value,out string status) {
        value=null;
        status="";
        try {
            var r=new LuaReader(lua);
            byte[] magic=r.Read(4);
            if(magic[0]!=0x1B||magic[1]!=(byte)'L'||magic[2]!=(byte)'u'||magic[3]!=(byte)'a')
                throw new InvalidDataException("not Lua bytecode");
            if(r.U8()!=0x50)throw new InvalidDataException("not Lua 5.0");
            if(r.U8()!=1)throw new InvalidDataException("unsupported Lua endianness");
            byte[] expected=new byte[]{4,4,4,6,8,9,9,8};
            for(int i=0;i<expected.Length;i++)if(r.U8()!=expected[i])throw new InvalidDataException("unexpected Lua header layout");
            r.F64(); r.Str(); r.I32(); r.U8(); r.U8(); r.U8(); int maxstack=r.U8();
            int nline=r.I32(); for(int i=0;i<nline;i++)r.I32();
            int nloc=r.I32(); for(int i=0;i<nloc;i++){r.Str();r.I32();r.I32();}
            int nuv=r.I32(); for(int i=0;i<nuv;i++)r.Str();
            int nk=r.I32();
            object[] constants=new object[nk];
            for(int i=0;i<nk;i++) {
                byte t=r.U8();
                if(t==0)constants[i]=null;
                else if(t==3)constants[i]=r.F64();
                else if(t==4)constants[i]=r.Str();
                else throw new InvalidDataException("unsupported Lua constant type "+t);
            }
            int np=r.I32();
            if(np!=0)throw new InvalidDataException("nested Lua prototype not supported");
            int nc=r.I32();
            uint[] code=new uint[nc]; for(int i=0;i<nc;i++)code[i]=r.U32();
            object[] regs=new object[Math.Max(300,maxstack+16)];
            for(int pc=0;pc<code.Length;pc++) {
                uint ins=code[pc];
                int op=(int)(ins&63);
                int C=(int)((ins>>6)&511);
                int B=(int)((ins>>15)&511);
                int A=(int)((ins>>24)&255);
                int Bx=(int)((ins>>6)&0x3ffff);
                if(op==0) regs[A]=regs[B];
                else if(op==1) regs[A]=(Bx>=0&&Bx<constants.Length)?constants[Bx]:null;
                else if(op==7) {
                    string key=(Bx>=0&&Bx<constants.Length)?constants[Bx] as string:null;
                    if(String.Equals(key,fieldName,StringComparison.Ordinal)&&AcceptFieldValue(regs[A],stringOnly)) {
                        value=regs[A]; status="exact Lua 5.0 SETGLOBAL"; return true;
                    }
                }
                else if(op==9) {
                    if(B>=250&&C>=250) {
                        int kb=B-250,kv=C-250;
                        if(kb>=0&&kb<constants.Length&&kv>=0&&kv<constants.Length) {
                            string key=constants[kb] as string;
                            if(String.Equals(key,fieldName,StringComparison.Ordinal)&&AcceptFieldValue(constants[kv],stringOnly)) {
                                value=constants[kv]; status="exact Lua 5.0 SETTABLE constant"; return true;
                            }
                        }
                    }
                }
            }
            status="Lua 5.0 field assignment not found";
        } catch(Exception ex) { status=ex.GetType().Name+": "+ex.Message; }
        return false;
    }

    static string[] ExtractStringFieldLua50(byte[] lua,string fieldName) {
        object value; string status;
        bool ok=TryExtractFieldLua50(lua,fieldName,true,out value,out status);
        return new string[]{(ok&&value is string)?(string)value:"",status};
    }

    static LuaReader OpenLua54Reader(byte[] lua) {
        var r=new LuaReader(lua);
        byte[] magic=r.Read(4);
        if(magic[0]!=0x1B||magic[1]!=(byte)'L'||magic[2]!=(byte)'u'||magic[3]!=(byte)'a')
            throw new InvalidDataException("not Lua bytecode");
        if(r.U8()!=0x54)throw new InvalidDataException("not Lua 5.4");
        if(r.U8()!=0)throw new InvalidDataException("unsupported Lua 5.4 format");
        byte[] luacData=new byte[]{0x19,0x93,0x0D,0x0A,0x1A,0x0A};
        for(int i=0;i<luacData.Length;i++)if(r.U8()!=luacData[i])throw new InvalidDataException("unexpected Lua 5.4 signature data");
        int instructionSize=r.U8(); int integerSize=r.U8(); int numberSize=r.U8();
        if(instructionSize!=4||integerSize!=8||numberSize!=8)throw new InvalidDataException("unsupported Lua 5.4 scalar layout");
        if(r.I64()!=0x5678)throw new InvalidDataException("unsupported Lua 5.4 endianness");
        if(Math.Abs(r.F64()-370.5)>0.000001)throw new InvalidDataException("unexpected Lua 5.4 number format");
        r.U8(); // main closure upvalue count
        return r;
    }

    static string[] ExtractStringFieldLua54(byte[] lua,string fieldName) {
        string value="",status="";
        try {
            var r=OpenLua54Reader(lua);
            if(ScanLua54PrototypeForStringField(r,fieldName,0,out value,out status))
                return new string[]{value,status};
        } catch(Exception ex) { status=ex.GetType().Name+": "+ex.Message; }
        return new string[]{value,status};
    }

    // Raw (typed) field value. Returns { value, status }; value is a string, a numeric box, or null.
    public static object[] ExtractLuaFieldValue(byte[] lua,string fieldName) {
        if(lua==null||lua.Length<5||String.IsNullOrWhiteSpace(fieldName))return new object[]{null,"invalid input"};
        if(lua[0]!=0x1B||lua[1]!=(byte)'L'||lua[2]!=(byte)'u'||lua[3]!=(byte)'a')return new object[]{null,"not Lua bytecode"};
        if(lua[4]==0x50) {
            object value; string status;
            bool ok=TryExtractFieldLua50(lua,fieldName,false,out value,out status);
            return new object[]{ok?value:null,status};
        }
        if(lua[4]==0x54) {
            object value=null; string status="";
            try {
                var r=OpenLua54Reader(lua);
                if(ScanLua54PrototypeForField(r,fieldName,0,false,out value,out status))return new object[]{value,status};
            } catch(Exception ex) { status=ex.GetType().Name+": "+ex.Message; }
            return new object[]{null,status};
        }
        return new object[]{null,"unsupported Lua version 0x"+lua[4].ToString("X2")};
    }

    // Only a positive 32-bit game MapID is a usable declared identity. Anything else (absent,
    // malformed, out of range) is reported as "no declared id" rather than coerced.
    static long? ToGameMapIdValue(object v) {
        long? i=null;
        if(v is long)i=(long)v;
        else if(v is int)i=(int)v;
        else if(v is double){ double d=(double)v; if(d>=-2147483648.0&&d<=2147483647.0)i=(long)Math.Round(d); }
        if(!i.HasValue)return null;
        if(i.Value<=0||i.Value>Int32.MaxValue)return null;
        return i;
    }

    // Reads the resource's own declared identity record (`Map\Common Map\MapNN\LapDistanceFile.luc`).
    // Nothing here assumes the folder number relates to the game MapID: the declared `mapId` is
    // reported as data and the catalog/binding layers decide what it means.
    public static LapDistanceInfo[] ParseLapDistanceDescriptors(CatalogNode[] nodes) {
        var output=new List<LapDistanceInfo>();
        if(nodes==null)return output.ToArray();

        foreach(var n in nodes) {
            if(n==null||String.IsNullOrWhiteSpace(n.FullPath))continue;
            var m=System.Text.RegularExpressions.Regex.Match(
                n.FullPath,
                @"^Map\\Common Map\\Map(\d+)\\LapDistanceFile\.luc$",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase
            );
            if(!m.Success)continue;

            int mapId;
            if(!Int32.TryParse(m.Groups[1].Value,out mapId))continue;

            var info=new LapDistanceInfo();
            info.MapId=mapId;
            info.Vfs=n.Vfs??"";
            info.FullPath=n.FullPath??"";
            info.Md5="";
            info.MapName="";
            info.DeclaredGameMapId=null;
            info.Parsed=false;
            info.ParseStatus="";
            try {
                byte[] bytes=ExtractDecoded(n);
                if(bytes==null) {
                    info.ParseStatus="ExtractDecoded returned null";
                } else {
                    info.Md5=Md5Hex(bytes);
                    object[] nameHit=ExtractLuaFieldValue(bytes,"mapName");
                    object[] idHit=ExtractLuaFieldValue(bytes,"mapId");
                    string name=(nameHit!=null&&nameHit.Length>0)?(nameHit[0] as string):null;
                    long? declared=ToGameMapIdValue(idHit!=null&&idHit.Length>0?idHit[0]:null);
                    info.MapName=String.IsNullOrWhiteSpace(name)?"":name;
                    info.DeclaredGameMapId=declared;
                    info.Parsed=!String.IsNullOrWhiteSpace(info.MapName)||declared.HasValue;
                    info.ParseStatus=(nameHit!=null&&nameHit.Length>1)?((string)nameHit[1]):"";
                }
            } catch(Exception ex) {
                info.ParseStatus=ex.GetType().Name+": "+ex.Message;
            }
            output.Add(info);
        }
        return output.ToArray();
    }

    static bool TryExtractMapNameLua54(byte[] lua,out string mapName,out string status) {
        string[] r=ExtractStringFieldLua54(lua,"map_name");
        mapName=(r!=null&&r.Length>0)?r[0]:"";
        status=(r!=null&&r.Length>1)?r[1]:"Lua 5.4 map_name assignment not found";
        return !String.IsNullOrWhiteSpace(mapName);
    }

    // Public adapter retained for the PowerShell MapCatalog layer.
    // The parser implementation itself stays centralized in the Lua 5.0/5.4
    // helpers above; callers should not reimplement descriptor parsing.
    public static DescriptorInfo ParseDescriptorBytes(int mapId,string source,byte[] bytes) {
        var info=new DescriptorInfo();
        info.MapId=mapId;
        info.Vfs=source??"";
        info.FullPath="";
        info.Md5=Md5Hex(bytes);
        info.MapName="";
        info.Parsed=false;
        info.ParseStatus="";

        if(bytes==null||bytes.Length<5) {
            info.ParseStatus="descriptor payload missing or too short";
            return info;
        }
        if(bytes[0]!=0x1B||bytes[1]!=(byte)'L'||bytes[2]!=(byte)'u'||bytes[3]!=(byte)'a') {
            info.ParseStatus="not Lua bytecode";
            return info;
        }

        string mapName="",status="";
        bool ok=false;
        if(bytes[4]==0x50) ok=TryExtractMapNameLua50(bytes,out mapName,out status);
        else if(bytes[4]==0x54) ok=TryExtractMapNameLua54(bytes,out mapName,out status);
        else status="unsupported Lua version 0x"+bytes[4].ToString("X2");

        info.MapName=mapName??"";
        info.Parsed=ok&&!String.IsNullOrWhiteSpace(info.MapName);
        info.ParseStatus=String.IsNullOrWhiteSpace(status)
            ? (info.Parsed?"parsed":"map_name unavailable")
            : status;
        return info;
    }

    public static DescriptorInfo[] ParseMapDescriptors(CatalogNode[] nodes) {
        var output=new List<DescriptorInfo>();
        if(nodes==null)return output.ToArray();

        foreach(var n in nodes) {
            if(n==null||String.IsNullOrWhiteSpace(n.FullPath))continue;
            var m=System.Text.RegularExpressions.Regex.Match(
                n.FullPath,
                @"^Map\\Common Map\\Map(\d+)\\map_desc\.luc$",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase
            );
            if(!m.Success)continue;

            int mapId;
            if(!Int32.TryParse(m.Groups[1].Value,out mapId))continue;
            DescriptorInfo info;
            try {
                byte[] bytes=ExtractDecoded(n);
                info=ParseDescriptorBytes(mapId,n.Vfs,bytes);
                if(bytes==null)info.ParseStatus="ExtractDecoded returned null";
            } catch(Exception ex) {
                info=new DescriptorInfo {
                    MapId=mapId,
                    Vfs=n.Vfs??"",
                    FullPath=n.FullPath??"",
                    Md5="",
                    MapName="",
                    Parsed=false,
                    ParseStatus=ex.GetType().Name+": "+ex.Message
                };
            }
            info.FullPath=n.FullPath??"";
            if(String.IsNullOrWhiteSpace(info.Vfs))info.Vfs=n.Vfs??"";
            output.Add(info);
        }
        return output.ToArray();
    }

    public static string[] ExtractLuaStringField(byte[] lua,string fieldName) {
        if(lua==null||lua.Length<5||String.IsNullOrWhiteSpace(fieldName))return new string[]{"","invalid input"};
        if(lua[0]!=0x1B||lua[1]!=(byte)'L'||lua[2]!=(byte)'u'||lua[3]!=(byte)'a')return new string[]{"","not Lua bytecode"};
        if(lua[4]==0x50)return ExtractStringFieldLua50(lua,fieldName);
        if(lua[4]==0x54)return ExtractStringFieldLua54(lua,fieldName);
        return new string[]{"","unsupported Lua version 0x"+lua[4].ToString("X2")};
    }

    static bool ContainsBytes(byte[] hay,byte[] needle) {
        if(hay==null||needle==null||needle.Length==0||hay.Length<needle.Length)return false;
        for(int i=0;i<=hay.Length-needle.Length;i++) {
            int j=0;
            for(;j<needle.Length;j++) if(hay[i+j]!=needle[j])break;
            if(j==needle.Length)return true;
        }
        return false;
    }

    public static bool ContainsEncodedText(byte[] data,string text) {
        if(data==null||String.IsNullOrWhiteSpace(text))return false;
        byte[] gbk=Encoding.GetEncoding(936).GetBytes(text);
        byte[] utf8=Encoding.UTF8.GetBytes(text);
        byte[] u16=Encoding.Unicode.GetBytes(text);
        return ContainsBytes(data,gbk)||ContainsBytes(data,utf8)||ContainsBytes(data,u16);
    }

    public static int[] SearchDescriptorTextIds(string gamePath,string text) {
        if(String.IsNullOrWhiteSpace(text))return new int[0];
        byte[] gbk=Encoding.GetEncoding(936).GetBytes(text);
        byte[] utf8=Encoding.UTF8.GetBytes(text);
        var ids=new HashSet<int>();
        CatalogNode[] nodes=ParseAllMapNodes(gamePath);

        foreach(var n in nodes) {
            if(String.IsNullOrEmpty(n.FullPath))continue;
            var m=System.Text.RegularExpressions.Regex.Match(
                n.FullPath,
                @"^Map\\Common Map\\Map(\d+)\\map_desc\.luc$",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase
            );
            if(!m.Success)continue;

            byte[] d=ExtractDecoded(n);
            if(d==null)continue;
            if(ContainsBytes(d,gbk)||ContainsBytes(d,utf8))ids.Add(Int32.Parse(m.Groups[1].Value));
        }
        return ids.OrderBy(x=>x).ToArray();
    }
}
