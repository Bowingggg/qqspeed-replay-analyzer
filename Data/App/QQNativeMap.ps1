param(
    [Parameter(Mandatory=$true)][int]$MapId,
    [string]$GamePath = '',
    [switch]$Force
)

$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$appDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir=Split-Path -Parent $appDir
$nativeRoot=Join-Path $dataDir ('NativeMaps\Map'+$MapId)
$metadataPath=Join-Path $nativeRoot 'metadata.json'
New-Item -ItemType Directory -Force -Path $nativeRoot | Out-Null

function Write-Utf8Bom([string]$Path,[string]$Text) {
    $enc=New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path,$Text,$enc)
}
function Get-GamePathFromSettings {
    $settings=Join-Path $dataDir 'settings.json'
    if(Test-Path -LiteralPath $settings -PathType Leaf){
        try{$j=Get-Content -LiteralPath $settings -Raw -Encoding UTF8|ConvertFrom-Json;$g=[string]$j.game_path;if(-not[string]::IsNullOrWhiteSpace($g)-and(Test-Path -LiteralPath $g -PathType Container)){return $g}}catch{}
    }
    return $null
}
if([string]::IsNullOrWhiteSpace($GamePath)){$GamePath=Get-GamePathFromSettings}
if([string]::IsNullOrWhiteSpace($GamePath)-or-not(Test-Path -LiteralPath $GamePath -PathType Container)){throw '尚未配置有效的 QQ飞车 游戏目录。'}

if(-not$Force -and (Test-Path -LiteralPath $metadataPath -PathType Leaf)){
    try{
        $cached=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8|ConvertFrom-Json
        if([string]$cached.contract -eq 'native_map_v1' -and [int]$cached.resource_map_id -eq $MapId -and -not[string]::IsNullOrWhiteSpace([string]$cached.geometry_sha256)){
            $svg=Join-Path $nativeRoot ([string]$cached.vector_minimap)
            if(Test-Path -LiteralPath $svg -PathType Leaf){Write-Host ('[NativeMap] Map'+$MapId+' cache ready · '+$svg);exit 0}
        }
    }catch{}
}

$cs=@"
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;

public sealed class MMGNode {
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

public sealed class MMGVec3 {
    public double X;
    public double Y;
    public double Z;
    public MMGVec3() {}
    public MMGVec3(double x,double y,double z){X=x;Y=y;Z=z;}
}

public sealed class MMGTransform {
    public MMGVec3 T = new MMGVec3(0,0,0);
    public double[] R = new double[]{1,0,0,0,1,0,0,0,1};
    public double S = 1.0;
    public uint Flags = 0;
    public string Name = "";
}

public sealed class MMGTriangle {
    public ushort A;
    public ushort B;
    public ushort C;
    public MMGTriangle(ushort a,ushort b,ushort c){A=a;B=b;C=c;}
}

public sealed class MMGMesh {
    public int ShapeBlock;
    public int DataBlock;
    public string ShapeType = "";
    public string DataType = "";
    public string Name = "";
    public bool Hidden;
    public MMGTransform World = new MMGTransform();
    public List<MMGVec3> Vertices = new List<MMGVec3>();
    public List<MMGTriangle> Triangles = new List<MMGTriangle>();
}

public sealed class MMGProjection {
    public string Name;
    public double MinA;
    public double MaxA;
    public double MinB;
    public double MaxB;
    public double MinDepth;
    public double MaxDepth;
    public double SpanA;
    public double SpanB;
    public double DepthSpan;
    public double ThicknessRatio;
    public int VisibleTriangles;
    public string SvgPath;
}

public sealed class MMGShapeReport {
    public int ShapeBlock;
    public int DataBlock;
    public string ShapeType;
    public string DataType;
    public string Name;
    public bool Hidden;
    public int Vertices;
    public int Triangles;
}

public sealed class MMGNifReport {
    public bool Success;
    public string Error;
    public string HeaderString;
    public uint Version;
    public uint UserVersion;
    public uint UserVersion2;
    public string ReaderLayout;
    public int NumBlocks;
    public string[] BlockTypes;
    public int ShapeBlocks;
    public int DecodedShapes;
    public int HiddenShapes;
    public int TotalVertices;
    public int TotalTriangles;
    public string BestProjection;
    public double BestThicknessRatio;
    public bool PlanarCandidate;
    public MMGProjection XY;
    public MMGProjection XZ;
    public MMGProjection YZ;
    public MMGShapeReport[] Shapes;
    public string[] Warnings;
}

public sealed class MMGMapResult {
    public int MapId;
    public int CandidateCount;
    public int SuccessfulCandidates;
    public string Status;
    public string BestNifPath;
    public string BestVfs;
    public string BestSha256;
    public string BestExtractedPath;
    public MMGNifReport BestGeometry;
    public MMGNifReport[] CandidateReports;
}

public static class QQOfficialMinimapGeometryCore {
    static readonly byte[] Alphabet=Encoding.ASCII.GetBytes("QSPEDIKJHMNATOGC");
    static readonly int[] S2N=BuildReverse();
    const uint NIF_20_2_0_7 = 0x14020007u;
    const uint NIF_QQSPEED_20_2_5_22 = 0x14020516u;
    const uint NIF_QQSPEED_20_2_5_23 = 0x14020517u;

    sealed class Reader {
        public byte[] D;
        public int P;
        public Reader(byte[] d){D=d;P=0;}
        public int Left { get { return D.Length-P; } }
        public void Need(int n){if(n<0||P<0||P+n>D.Length)throw new InvalidDataException("NIF read out of range");}
        public byte U8(){Need(1);return D[P++];}
        public ushort U16(){Need(2);ushort v=BitConverter.ToUInt16(D,P);P+=2;return v;}
        public uint U32(){Need(4);uint v=BitConverter.ToUInt32(D,P);P+=4;return v;}
        public int I32(){Need(4);int v=BitConverter.ToInt32(D,P);P+=4;return v;}
        public float F32(){Need(4);float v=BitConverter.ToSingle(D,P);P+=4;return v;}
        public void Skip(int n){Need(n);P+=n;}
        public void Seek(int p){if(p<0||p>D.Length)throw new InvalidDataException("NIF seek out of range");P=p;}
        public string SizedString(){uint n=U32(); if(n>1048576)throw new InvalidDataException("NIF sized string too large"); Need((int)n); string s=Encoding.UTF8.GetString(D,P,(int)n); P+=(int)n; return s.TrimEnd('\0');}
        public string ShortString(){int n=U8(); Need(n); string s=Encoding.UTF8.GetString(D,P,n); P+=n; return s.TrimEnd('\0');}
        public int[] Refs(){uint n=U32(); if(n>100000)throw new InvalidDataException("NIF ref array too large"); int[] a=new int[n]; for(int i=0;i<a.Length;i++)a[i]=I32(); return a;}
        public MMGVec3 V3(){return new MMGVec3(F32(),F32(),F32());}
        public double[] M33(){double[] a=new double[9];for(int i=0;i<9;i++)a[i]=F32();return a;}
    }

    sealed class Header {
        public string HeaderString;
        public uint Version;
        public uint UserVersion;
        public uint UserVersion2;
        public uint NumBlocks;
        public string[] BlockTypes;
        public ushort[] BlockTypeIndex;
        public uint[] BlockSizes;
        public string[] Strings;
        public int BodyOffset;
        public string TypeOf(int i){if(i<0||i>=BlockTypeIndex.Length)return "";int ti=BlockTypeIndex[i];return ti>=0&&ti<BlockTypes.Length?BlockTypes[ti]:"";}
        public string StringAt(uint idx){return idx<Strings.Length?Strings[idx]:"";}
    }

    sealed class ShapeInfo {
        public int Block;
        public int DataRef;
        public string Type;
        public MMGTransform Local;
    }

    static int[] BuildReverse() {
        int[] r=Enumerable.Repeat(-1,256).ToArray();
        for(int i=0;i<Alphabet.Length;i++)r[Alphabet[i]]=i;
        return r;
    }

    static uint U32(byte[] b,int o){return BitConverter.ToUInt32(b,o);}

    static byte[] ReadExact(Stream s,int n) {
        byte[] b=new byte[n]; int got=0;
        while(got<n){int k=s.Read(b,got,n-got);if(k<=0)throw new EndOfStreamException();got+=k;}
        return b;
    }

    static byte[] DecodeIndex(byte[] enc) {
        if((enc.Length&1)!=0)throw new InvalidDataException("odd index payload");
        byte[] d=new byte[enc.Length/2];
        for(int i=0;i<d.Length;i++){
            int hi=S2N[enc[i*2]],lo=S2N[enc[i*2+1]];
            if(hi<0||lo<0)throw new InvalidDataException("unknown VFS index symbol");
            d[i]=(byte)((hi<<4)|lo);
        }
        return d;
    }

    static string AsciiName(byte[] b,int o,int n) {
        var sb=new StringBuilder(n);
        for(int i=0;i<n;i++){byte x=b[o+i];sb.Append(x>=32&&x<127?(char)x:'?');}
        return sb.ToString();
    }

    public static MMGNode[] ParseAllMapNodes(string gamePath) {
        var output=new List<MMGNode>();
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
                    var local=new List<MMGNode>();
                    for(int ei=0;ei<count;ei++) {
                        byte[] bh=ReadExact(fs,8);
                        uint encLen=BitConverter.ToUInt32(bh,0),decLen=BitConverter.ToUInt32(bh,4);
                        if(encLen!=decLen*2||decLen<60||encLen>2*1024*1024)throw new InvalidDataException("bad VFS index block");
                        byte[] d=DecodeIndex(ReadExact(fs,(int)encLen));
                        if(U32(d,0)!=0x68656164||U32(d,d.Length-4)!=0x7461696c)throw new InvalidDataException("bad VFS index record markers");
                        uint nameLen=U32(d,4); if(nameLen+60!=d.Length)throw new InvalidDataException("bad VFS record length");
                        string name=AsciiName(d,8,(int)nameLen); int m=8+(int)nameLen;
                        local.Add(new MMGNode{Vfs=Path.GetFileName(vfsPath),VfsPath=vfsPath,IndexOffset=idx,VirtualAddress=virtualAddress,Name=name,OriginalSize=U32(d,m),StoredSize=U32(d,m+4),Type=U32(d,m+8),DataOffset=U32(d,m+12),Parent=U32(d,m+16),FullPath=""});
                        virtualAddress+=decLen;
                    }
                    var byAddr=local.ToDictionary(x=>x.VirtualAddress,x=>x); var cache=new Dictionary<long,string>();
                    Func<MMGNode,HashSet<long>,string> build=null;
                    build=(n,stack)=>{
                        string cached;if(cache.TryGetValue(n.VirtualAddress,out cached))return cached;
                        if(stack.Contains(n.VirtualAddress))throw new InvalidDataException("parent cycle");stack.Add(n.VirtualAddress);
                        string path;
                        if(n.Parent==0)path=n.Name;
                        else {MMGNode par;if(!byAddr.TryGetValue((long)n.Parent,out par))throw new InvalidDataException("parent pointer not found");string pp=build(par,stack);path=String.IsNullOrEmpty(pp)?n.Name:(pp+"\\"+n.Name);}
                        stack.Remove(n.VirtualAddress);cache[n.VirtualAddress]=path;return path;
                    };
                    foreach(var n in local){try{n.FullPath=build(n,new HashSet<long>());}catch{n.FullPath="";}if(!String.IsNullOrEmpty(n.FullPath)&&n.FullPath.StartsWith(@"Map\Common Map\Map",StringComparison.OrdinalIgnoreCase))output.Add(n);}
                }
            } catch {}
        }
        return output.ToArray();
    }

    public static byte[] ExtractDecoded(MMGNode n) {
        if(n==null||n.Type!=1||n.StoredSize==0||n.DataOffset==0)return null;
        var blocks=new List<byte[]>(); long remaining=n.StoredSize,current=n.DataOffset;var seen=new HashSet<long>();
        using(var fs=new FileStream(n.VfsPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
            while(remaining>0){
                if(current<=0||current+16>n.IndexOffset||!seen.Add(current))return null;
                fs.Seek(current,SeekOrigin.Begin);byte[] hdr=ReadExact(fs,16);
                if(BitConverter.ToUInt32(hdr,0)!=0x68656164)return null;
                uint link=BitConverter.ToUInt32(hdr,8),payloadLen=BitConverter.ToUInt32(hdr,12);
                if(payloadLen==0||payloadLen>remaining||current+16L+payloadLen>n.IndexOffset)return null;
                blocks.Add(ReadExact(fs,(int)payloadLen));remaining-=payloadLen;if(remaining==0)break;if(link==0)return null;current=link;
            }
        }
        byte[] compressed;using(var ms=new MemoryStream()){foreach(byte[] b in blocks)ms.Write(b,0,b.Length);compressed=ms.ToArray();}
        if(compressed.Length==n.OriginalSize)return compressed;
        if(compressed.Length>=6&&compressed[0]==0x78){try{using(var src=new MemoryStream(compressed,2,compressed.Length-6,false))using(var ds=new DeflateStream(src,CompressionMode.Decompress))using(var dst=new MemoryStream()){ds.CopyTo(dst);byte[] d=dst.ToArray();if(d.Length==n.OriginalSize)return d;}}catch{}}
        try{using(var dst=new MemoryStream()){foreach(byte[] b in blocks){if(b.Length<6||b[0]!=0x78)return null;using(var src=new MemoryStream(b,2,b.Length-6,false))using(var ds=new DeflateStream(src,CompressionMode.Decompress)){ds.CopyTo(dst);}}byte[] d=dst.ToArray();if(d.Length==n.OriginalSize)return d;}}catch{}
        return null;
    }

    public static string Sha256(byte[] d){using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(d)).Replace("-","").ToLowerInvariant();}

    static Header ReadHeader(byte[] data) {
        int nl=Array.IndexOf<byte>(data,10,0,Math.Min(data.Length,160));
        if(nl<0)throw new InvalidDataException("NIF header line missing");
        string line=Encoding.ASCII.GetString(data,0,nl);
        if(line.IndexOf("Gamebryo File Format",StringComparison.OrdinalIgnoreCase)<0&&line.IndexOf("NetImmerse File Format",StringComparison.OrdinalIgnoreCase)<0)throw new InvalidDataException("not a Gamebryo/NetImmerse NIF");
        var r=new Reader(data);r.P=nl+1;
        var h=new Header();h.HeaderString=line;h.Version=r.U32();
        if(h.Version>=0x14000004u){if(r.U8()!=1)throw new InvalidDataException("big-endian NIF not supported");}
        h.UserVersion=h.Version>=0x0A010000u?r.U32():0u;
        h.NumBlocks=r.U32();
        if(h.NumBlocks>200000)throw new InvalidDataException("unreasonable NIF block count");
        if(h.Version==0x0A000102u){r.U32();r.ShortString();r.ShortString();r.ShortString();}
        else if(h.Version>=0x0A010000u&&(h.UserVersion>=10u||(h.UserVersion==1u&&h.Version!=0x0A020000u))){
            h.UserVersion2=r.U32();r.ShortString();if(h.UserVersion2>130u)r.U32();r.ShortString();r.ShortString();if(h.UserVersion2==130u)r.ShortString();
        }
        ushort ntypes=h.Version>=0x0A000100u?r.U16():(ushort)0;
        h.BlockTypes=new string[ntypes];for(int i=0;i<ntypes;i++)h.BlockTypes[i]=r.SizedString();
        h.BlockTypeIndex=new ushort[h.NumBlocks];for(int i=0;i<h.BlockTypeIndex.Length;i++)h.BlockTypeIndex[i]=r.U16();
        h.BlockSizes=new uint[h.NumBlocks];if(h.Version>=0x14020005u){for(int i=0;i<h.BlockSizes.Length;i++)h.BlockSizes[i]=r.U32();}
        uint nstrings=h.Version>=0x14010003u?r.U32():0u;if(nstrings>200000)throw new InvalidDataException("unreasonable NIF string count");if(h.Version>=0x14010003u)r.U32();
        h.Strings=new string[nstrings];for(int i=0;i<h.Strings.Length;i++)h.Strings[i]=r.SizedString();
        if(h.Version>=0x05000006u){uint ng=r.U32();if(ng>100000)throw new InvalidDataException("unreasonable NIF group count");for(uint i=0;i<ng;i++)r.U32();}
        if(h.Version>=0x0A000100u&&h.Version<0x0A020000u)r.U32();
        h.BodyOffset=r.P;return h;
    }

    static MMGTransform ReadAv(Reader r,Header h) {
        var a=new MMGTransform();uint nameIdx=UInt32.MaxValue;if(h.Version>=0x14010003u)nameIdx=r.U32();r.Refs();r.I32();
        a.Flags=h.UserVersion2>26u?r.U32():r.U16();a.T=r.V3();a.R=r.M33();a.S=r.F32();
        if(h.UserVersion2<=34u)r.Refs();r.I32();a.Name=nameIdx!=UInt32.MaxValue?h.StringAt(nameIdx):"";
        if(h.Version==NIF_QQSPEED_20_2_5_23){
            // Verified from Map348 official eagle-map blocks: 20.2.5.23 adds a strict
            // five-byte AV tail after Collision Object: byte 0 + uint32 23.
            // Fail closed on any other signature; do not guess newer QQSpeed layouts.
            byte marker=r.U8();uint tag=r.U32();
            if(marker!=0||tag!=23u)throw new InvalidDataException("QQSpeed 20.2.5.23 AV-tail signature mismatch");
            ValidateTransform(a);
        } else if(h.Version==NIF_QQSPEED_20_2_5_22){
            // Verified from Map329 official eagle-map blocks: 20.2.5.22 uses the SAME AV struct and
            // the SAME one-byte marker, but without the uint32 tag 20.2.5.23 appends after it.
            // Byte-for-byte comparison against Map348 (20.2.5.22 vs 20.2.5.23, both 5-block
            // Unity-exported eagle maps) shows the 20.2.5.22 NiNode/NiTriShape blocks are exactly
            // four bytes shorter and otherwise identical; dropping the one uint32 makes the
            // NiTriShape geometry reference resolve to the NiTriShapeData block and the NiNode
            // child list resolve to the NiTriShape, and reproduces the same trailing byte count.
            // The marker byte is still a hard signature gate: anything else fails closed.
            byte marker=r.U8();
            if(marker!=0)throw new InvalidDataException("QQSpeed 20.2.5.22 AV-tail signature mismatch");
            ValidateTransform(a);
        }
        return a;
    }

    static bool Finite(double x){return !Double.IsNaN(x)&&!Double.IsInfinity(x);}
    static double RotationOrthoError(double[] m){
        double e=0;
        for(int r=0;r<3;r++){double n=m[r*3]*m[r*3]+m[r*3+1]*m[r*3+1]+m[r*3+2]*m[r*3+2];e=Math.Max(e,Math.Abs(n-1.0));}
        for(int a=0;a<3;a++)for(int b=a+1;b<3;b++){double d=m[a*3]*m[b*3]+m[a*3+1]*m[b*3+1]+m[a*3+2]*m[b*3+2];e=Math.Max(e,Math.Abs(d));}
        return e;
    }
    static void ValidateTransform(MMGTransform a){
        if(!Finite(a.T.X)||!Finite(a.T.Y)||!Finite(a.T.Z)||!Finite(a.S)||Math.Abs(a.S)<1e-8||Math.Abs(a.S)>1000000.0)throw new InvalidDataException("invalid AV transform");
        for(int i=0;i<a.R.Length;i++)if(!Finite(a.R[i]))throw new InvalidDataException("invalid AV rotation");
        double ortho=RotationOrthoError(a.R);if(ortho>0.02)throw new InvalidDataException("non-orthonormal AV rotation");
    }

    static string ReaderLayout(Header h){
        if(h.Version==NIF_QQSPEED_20_2_5_23)return "qqspeed_20_2_5_23_av_tail_v1";
        if(h.Version==NIF_QQSPEED_20_2_5_22)return "qqspeed_20_2_5_22_av_marker_v1";
        return "standard_gamebryo_av_v1";
    }

    static double[] MatMul(double[] a,double[] b){var o=new double[9];for(int rr=0;rr<3;rr++)for(int c=0;c<3;c++)o[rr*3+c]=a[rr*3]*b[c]+a[rr*3+1]*b[3+c]+a[rr*3+2]*b[6+c];return o;}
    static MMGTransform WorldTransform(int idx,Dictionary<int,MMGTransform> local,Dictionary<int,int> parent){
        var chain=new List<int>();var seen=new HashSet<int>();int cur=idx;while(cur>=0&&!seen.Contains(cur)){seen.Add(cur);chain.Add(cur);int p;if(!parent.TryGetValue(cur,out p))break;cur=p;}
        var w=new MMGTransform();
        for(int ci=chain.Count-1;ci>=0;ci--){MMGTransform l;if(!local.TryGetValue(chain[ci],out l))continue;double x=w.R[0]*l.T.X+w.R[1]*l.T.Y+w.R[2]*l.T.Z;double y=w.R[3]*l.T.X+w.R[4]*l.T.Y+w.R[5]*l.T.Z;double z=w.R[6]*l.T.X+w.R[7]*l.T.Y+w.R[8]*l.T.Z;w.T=new MMGVec3(w.T.X+w.S*x,w.T.Y+w.S*y,w.T.Z+w.S*z);w.R=MatMul(w.R,l.R);w.S*=l.S;w.Flags|=l.Flags;if(String.IsNullOrEmpty(w.Name)&&!String.IsNullOrEmpty(l.Name))w.Name=l.Name;}
        return w;
    }
    static MMGVec3 Apply(MMGTransform w,MMGVec3 v){double x=w.R[0]*v.X+w.R[1]*v.Y+w.R[2]*v.Z;double y=w.R[3]*v.X+w.R[4]*v.Y+w.R[5]*v.Z;double z=w.R[6]*v.X+w.R[7]*v.Y+w.R[8]*v.Z;return new MMGVec3(w.T.X+w.S*x,w.T.Y+w.S*y,w.T.Z+w.S*z);}
    static bool HiddenInGraph(int idx,Dictionary<int,MMGTransform> local,Dictionary<int,int> parent){var seen=new HashSet<int>();int cur=idx;while(cur>=0&&!seen.Contains(cur)){seen.Add(cur);MMGTransform a;if(local.TryGetValue(cur,out a)&&(a.Flags&1u)!=0)return true;int p;if(!parent.TryGetValue(cur,out p))break;cur=p;}return false;}

    static MMGMesh ReadGeometry(byte[] block,Header h,string type,int shapeBlock,int dataBlock,MMGTransform world,bool hidden,string name) {
        var r=new Reader(block);if(h.Version>=0x0A010072u)r.I32();ushort nv=r.U16();if(h.Version>=0x0A010000u){r.U8();byte compress=r.U8();if(compress!=0)throw new InvalidDataException("compressed NiGeometryData not supported");}
        byte hv=r.U8();var verts=new List<MMGVec3>();if(hv!=0){for(int i=0;i<nv;i++)verts.Add(r.V3());}
        ushort dataFlags=h.Version>=0x0A000100u?r.U16():(ushort)0;bool bs202=h.Version==NIF_20_2_0_7&&h.UserVersion2>0u;if(bs202&&h.UserVersion2>34u)r.U32();
        byte hn=r.U8();if(hn!=0){r.Skip(nv*12);if((dataFlags&0x1000)!=0){r.Skip(nv*12);r.Skip(nv*12);}}
        r.Skip(16);byte hc=r.U8();if(hc!=0)r.Skip(nv*16);
        int uvSets=bs202?(dataFlags&1):(dataFlags&0x3F);if(uvSets>0)r.Skip(checked(nv*8*uvSets));
        if(h.Version>=0x0A000100u)r.U16();if(h.Version>=0x14000004u)r.I32();ushort nt=r.U16();var tris=new List<MMGTriangle>();
        if(type=="NiTriShapeData"){
            r.U32();byte ht=h.Version>=0x0A010000u?r.U8():(byte)1;if(ht!=0){for(int i=0;i<nt;i++)tris.Add(new MMGTriangle(r.U16(),r.U16(),r.U16()));}
        } else if(type=="NiTriStripsData"){
            ushort ns=r.U16();ushort[] lens=new ushort[ns];for(int i=0;i<ns;i++)lens[i]=r.U16();byte hp=h.Version>=0x0A000103u?r.U8():(byte)1;if(hp!=0){for(int s=0;s<ns;s++){ushort[] strip=new ushort[lens[s]];for(int j=0;j<strip.Length;j++)strip[j]=r.U16();for(int j=0;j+2<strip.Length;j++){ushort a=strip[j],b=strip[j+1],c=strip[j+2];if(a==b||b==c||a==c)continue;tris.Add((j&1)!=0?new MMGTriangle(a,c,b):new MMGTriangle(a,b,c));}}}
        }
        var m=new MMGMesh();m.ShapeBlock=shapeBlock;m.DataBlock=dataBlock;m.ShapeType="NiTriShape";m.DataType=type;m.Name=name;m.Hidden=hidden;m.World=world;foreach(var v in verts)m.Vertices.Add(Apply(world,v));m.Triangles=tris;return m;
    }

    static MMGProjection BuildProjection(string name,List<MMGMesh> meshes,int axA,int axB,int axD,string svgPath){
        var p=new MMGProjection();p.Name=name;p.SvgPath=svgPath;double minA=Double.PositiveInfinity,maxA=Double.NegativeInfinity,minB=Double.PositiveInfinity,maxB=Double.NegativeInfinity,minD=Double.PositiveInfinity,maxD=Double.NegativeInfinity;int valid=0;
        Func<MMGVec3,int,double> coord=(v,a)=>a==0?v.X:(a==1?v.Y:v.Z);
        foreach(var m in meshes){if(m.Hidden)continue;foreach(var v in m.Vertices){double a=coord(v,axA),b=coord(v,axB),d=coord(v,axD);if(Double.IsNaN(a)||Double.IsInfinity(a)||Double.IsNaN(b)||Double.IsInfinity(b)||Double.IsNaN(d)||Double.IsInfinity(d))continue;minA=Math.Min(minA,a);maxA=Math.Max(maxA,a);minB=Math.Min(minB,b);maxB=Math.Max(maxB,b);minD=Math.Min(minD,d);maxD=Math.Max(maxD,d);valid++;}p.VisibleTriangles+=m.Triangles.Count;}
        if(valid==0){p.MinA=p.MaxA=p.MinB=p.MaxB=p.MinDepth=p.MaxDepth=p.SpanA=p.SpanB=p.DepthSpan=0;p.ThicknessRatio=Double.PositiveInfinity;return p;}
        p.MinA=minA;p.MaxA=maxA;p.MinB=minB;p.MaxB=maxB;p.MinDepth=minD;p.MaxDepth=maxD;p.SpanA=maxA-minA;p.SpanB=maxB-minB;p.DepthSpan=maxD-minD;double denom=Math.Max(p.SpanA,p.SpanB);p.ThicknessRatio=denom>1e-9?p.DepthSpan/denom:Double.PositiveInfinity;
        WriteSvg(svgPath,name,meshes,axA,axB,minA,maxA,minB,maxB);return p;
    }

    static string F(double v){return v.ToString("0.###",CultureInfo.InvariantCulture);}
    static void WriteSvg(string path,string title,List<MMGMesh> meshes,int axA,int axB,double minA,double maxA,double minB,double maxB){
        Func<MMGVec3,int,double> coord=(v,a)=>a==0?v.X:(a==1?v.Y:v.Z);double sa=maxA-minA,sb=maxB-minB;if(sa<=0)sa=1;if(sb<=0)sb=1;double W=1200,H=1200,pad=35,scale=Math.Min((W-2*pad)/sa,(H-2*pad)/sb);double ox=(W-sa*scale)/2,oy=(H-sb*scale)/2;
        var sbld=new StringBuilder();sbld.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");sbld.Append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"1200\" viewBox=\"0 0 1200 1200\">\n");sbld.Append("<g data-render-style=\"clean_surface_no_triangle_grid_v1\" fill=\"#e3e3e3\" stroke=\"#e3e3e3\" stroke-width=\"0.9\" stroke-linejoin=\"round\">\n");
        foreach(var m in meshes){if(m.Hidden)continue;foreach(var t in m.Triangles){if(t.A>=m.Vertices.Count||t.B>=m.Vertices.Count||t.C>=m.Vertices.Count)continue;MMGVec3 va=m.Vertices[t.A],vb=m.Vertices[t.B],vc=m.Vertices[t.C];double ax=ox+(coord(va,axA)-minA)*scale,ay=H-(oy+(coord(va,axB)-minB)*scale),bx=ox+(coord(vb,axA)-minA)*scale,by=H-(oy+(coord(vb,axB)-minB)*scale),cx=ox+(coord(vc,axA)-minA)*scale,cy=H-(oy+(coord(vc,axB)-minB)*scale);sbld.Append("<polygon points=\"").Append(F(ax)).Append(',').Append(F(ay)).Append(' ').Append(F(bx)).Append(',').Append(F(by)).Append(' ').Append(F(cx)).Append(',').Append(F(cy)).Append("\"/>\n");}}
        sbld.Append("</g>\n</svg>\n");Directory.CreateDirectory(Path.GetDirectoryName(path));File.WriteAllText(path,sbld.ToString(),new UTF8Encoding(false));
    }

    public static MMGNifReport AnalyzeNif(byte[] data,string outputStem) {
        var report=new MMGNifReport();var warnings=new List<string>();
        try {
            Header h=ReadHeader(data);report.HeaderString=h.HeaderString;report.Version=h.Version;report.UserVersion=h.UserVersion;report.UserVersion2=h.UserVersion2;report.ReaderLayout=ReaderLayout(h);report.NumBlocks=(int)h.NumBlocks;report.BlockTypes=h.BlockTypes;
            if(h.BlockSizes==null||h.BlockSizes.Length!=(int)h.NumBlocks)throw new InvalidDataException("NIF block-size table unavailable");
            int[] offs=new int[h.NumBlocks];long pos=h.BodyOffset;for(int i=0;i<offs.Length;i++){if(pos<0||pos+h.BlockSizes[i]>data.Length)throw new InvalidDataException("NIF block table exceeds file");offs[i]=(int)pos;pos+=h.BlockSizes[i];}
            var local=new Dictionary<int,MMGTransform>();var parent=new Dictionary<int,int>();var shapes=new List<ShapeInfo>();
            for(int i=0;i<offs.Length;i++){
                string type=h.TypeOf(i);int size=(int)h.BlockSizes[i];if(size<=0)continue;byte[] block=new byte[size];Buffer.BlockCopy(data,offs[i],block,0,size);
                try{
                    if(type=="NiNode"){
                        var r=new Reader(block);MMGTransform av=ReadAv(r,h);local[i]=av;int[] children=r.Refs();foreach(int ch in children){if(ch>=0&&ch>=(int)h.NumBlocks)throw new InvalidDataException("NiNode child ref out of range");if(ch>=0)parent[ch]=i;}
                    } else if(type=="NiTriShape"||type=="NiTriStrips"){
                        var r=new Reader(block);MMGTransform av=ReadAv(r,h);local[i]=av;int dataRef=r.I32();int skinRef=r.I32();if(dataRef<0||dataRef>=(int)h.NumBlocks)throw new InvalidDataException("geometry data ref out of range");if(skinRef>=0&&skinRef>=(int)h.NumBlocks)throw new InvalidDataException("skin ref out of range");shapes.Add(new ShapeInfo{Block=i,DataRef=dataRef,Type=type,Local=av});
                    }
                }catch(Exception ex){warnings.Add("block "+i+" "+type+": "+ex.Message);}
            }
            report.ShapeBlocks=shapes.Count;var meshes=new List<MMGMesh>();var sr=new List<MMGShapeReport>();
            foreach(var sh in shapes){
                string dt=h.TypeOf(sh.DataRef);if(sh.DataRef<0||sh.DataRef>=offs.Length||(dt!="NiTriShapeData"&&dt!="NiTriStripsData")){warnings.Add("shape "+sh.Block+" data ref "+sh.DataRef+" type="+dt);continue;}
                try{int size=(int)h.BlockSizes[sh.DataRef];byte[] block=new byte[size];Buffer.BlockCopy(data,offs[sh.DataRef],block,0,size);MMGTransform world=WorldTransform(sh.Block,local,parent);bool hidden=HiddenInGraph(sh.Block,local,parent);MMGMesh m=ReadGeometry(block,h,dt,sh.Block,sh.DataRef,world,hidden,sh.Local.Name);m.ShapeType=sh.Type;meshes.Add(m);sr.Add(new MMGShapeReport{ShapeBlock=sh.Block,DataBlock=sh.DataRef,ShapeType=sh.Type,DataType=dt,Name=sh.Local.Name,Hidden=hidden,Vertices=m.Vertices.Count,Triangles=m.Triangles.Count});}
                catch(Exception ex){warnings.Add("shape "+sh.Block+" geometry: "+ex.Message);}
            }
            report.DecodedShapes=meshes.Count;report.HiddenShapes=meshes.Count(x=>x.Hidden);report.TotalVertices=meshes.Where(x=>!x.Hidden).Sum(x=>x.Vertices.Count);report.TotalTriangles=meshes.Where(x=>!x.Hidden).Sum(x=>x.Triangles.Count);report.Shapes=sr.ToArray();
            report.XY=BuildProjection("XY (game ground-plane candidate)",meshes,0,1,2,outputStem+"_xy.svg");report.XZ=BuildProjection("XZ",meshes,0,2,1,outputStem+"_xz.svg");report.YZ=BuildProjection("YZ",meshes,1,2,0,outputStem+"_yz.svg");
            MMGProjection best=new[]{report.XY,report.XZ,report.YZ}.OrderBy(x=>x.ThicknessRatio).First();report.BestProjection=best.Name;report.BestThicknessRatio=best.ThicknessRatio;report.PlanarCandidate=report.TotalTriangles>=4&&best.ThicknessRatio<=0.25;report.Warnings=warnings.ToArray();report.Success=report.DecodedShapes>0&&report.TotalTriangles>0;
            if(!report.Success)report.Error="No decodable visible NiTriShape/NiTriStrips geometry";
        } catch(Exception ex){report.Success=false;report.Error=ex.GetType().Name+": "+ex.Message;report.Warnings=warnings.ToArray();}
        return report;
    }

    static byte[] BuildSyntheticNif(){
        byte[] node,shape,geom;
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write((uint)0);w.Write((uint)0);w.Write(-1);w.Write((ushort)0);for(int i=0;i<3;i++)w.Write(0f);for(int i=0;i<9;i++)w.Write(i==0||i==4||i==8?1f:0f);w.Write(1f);w.Write((uint)0);w.Write(-1);w.Write((uint)1);w.Write(1);w.Write((uint)0);node=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write((uint)1);w.Write((uint)0);w.Write(-1);w.Write((ushort)0);w.Write(10f);w.Write(20f);w.Write(0f);for(int i=0;i<9;i++)w.Write(i==0||i==4||i==8?1f:0f);w.Write(1f);w.Write((uint)0);w.Write(-1);w.Write(2);w.Write(-1);shape=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write(0);w.Write((ushort)4);w.Write((byte)0);w.Write((byte)0);w.Write((byte)1);float[,] v={{0,0,0},{100,0,0},{100,50,0},{0,50,0}};for(int i=0;i<4;i++){w.Write(v[i,0]);w.Write(v[i,1]);w.Write(v[i,2]);}w.Write((ushort)0);w.Write((byte)0);for(int i=0;i<4;i++)w.Write(0f);w.Write((byte)0);w.Write((ushort)0);w.Write(-1);w.Write((ushort)2);w.Write((uint)6);w.Write((byte)1);w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)2);w.Write((ushort)0);w.Write((ushort)2);w.Write((ushort)3);w.Write((ushort)0);geom=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write(Encoding.ASCII.GetBytes("Gamebryo File Format, Version 20.2.0.7\n"));w.Write(NIF_20_2_0_7);w.Write((byte)1);w.Write((uint)0);w.Write((uint)3);w.Write((ushort)3);
            string[] types={"NiNode","NiTriShape","NiTriShapeData"};foreach(string s in types){byte[] b=Encoding.ASCII.GetBytes(s);w.Write((uint)b.Length);w.Write(b);}w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)2);w.Write((uint)node.Length);w.Write((uint)shape.Length);w.Write((uint)geom.Length);w.Write((uint)2);w.Write((uint)5);foreach(string s in new[]{"root","shape"}){byte[] b=Encoding.ASCII.GetBytes(s);w.Write((uint)b.Length);w.Write(b);}w.Write((uint)0);w.Write(node);w.Write(shape);w.Write(geom);return ms.ToArray();}
    }

    static byte[] BuildSyntheticModernNif(uint tailTag){
        byte[] node,shape,geom;
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write((uint)0);w.Write((uint)0);w.Write(-1);w.Write((ushort)0x10);for(int i=0;i<3;i++)w.Write(0f);for(int i=0;i<9;i++)w.Write(i==0||i==4||i==8?1f:0f);w.Write(1f);w.Write((uint)0);w.Write(-1);w.Write((byte)0);w.Write(tailTag);w.Write((uint)1);w.Write(1);node=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write((uint)1);w.Write((uint)0);w.Write(-1);w.Write((ushort)0x10);w.Write(10f);w.Write(20f);w.Write(0f);for(int i=0;i<9;i++)w.Write(i==0||i==4||i==8?1f:0f);w.Write(1f);w.Write((uint)0);w.Write(-1);w.Write((byte)0);w.Write(tailTag);w.Write(2);w.Write(-1);shape=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write(0);w.Write((ushort)4);w.Write((byte)0);w.Write((byte)0);w.Write((byte)1);float[,] v={{0,0,0},{100,0,0},{100,50,0},{0,50,0}};for(int i=0;i<4;i++){w.Write(v[i,0]);w.Write(v[i,1]);w.Write(v[i,2]);}w.Write((ushort)0);w.Write((byte)0);for(int i=0;i<4;i++)w.Write(0f);w.Write((byte)0);w.Write((ushort)0);w.Write(-1);w.Write((ushort)2);w.Write((uint)6);w.Write((byte)1);w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)2);w.Write((ushort)0);w.Write((ushort)2);w.Write((ushort)3);w.Write((ushort)0);geom=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write(Encoding.ASCII.GetBytes("Gamebryo File Format, Version 20.2.5.23\n"));w.Write(NIF_QQSPEED_20_2_5_23);w.Write((byte)1);w.Write((uint)0);w.Write((uint)3);w.Write((ushort)3);
            string[] types={"NiNode","NiTriShape","NiTriShapeData"};foreach(string x in types){byte[] b=Encoding.ASCII.GetBytes(x);w.Write((uint)b.Length);w.Write(b);}w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)2);w.Write((uint)node.Length);w.Write((uint)shape.Length);w.Write((uint)geom.Length);w.Write((uint)2);w.Write((uint)5);foreach(string x in new[]{"root","shape"}){byte[] b=Encoding.ASCII.GetBytes(x);w.Write((uint)b.Length);w.Write(b);}w.Write((uint)0);w.Write(node);w.Write(shape);w.Write(geom);return ms.ToArray();}
    }

    public static string SelfTest(string tempDir){
        Directory.CreateDirectory(tempDir);string stem=Path.Combine(tempDir,"synthetic");MMGNifReport r=AnalyzeNif(BuildSyntheticNif(),stem);if(!r.Success)throw new Exception("synthetic parse failed: "+r.Error);if(r.TotalVertices!=4||r.TotalTriangles!=2)throw new Exception("synthetic geometry count mismatch");if(r.XY.SpanA<99.9||r.XY.SpanB<49.9||r.XY.ThicknessRatio>0.0001)throw new Exception("synthetic projection mismatch");return "ok";
    }

    public static string SelfTestModern(string tempDir){
        Directory.CreateDirectory(tempDir);string stem=Path.Combine(tempDir,"synthetic_modern");MMGNifReport r=AnalyzeNif(BuildSyntheticModernNif(23u),stem);if(!r.Success)throw new Exception("modern synthetic parse failed: "+r.Error);if(r.ReaderLayout!="qqspeed_20_2_5_23_av_tail_v1")throw new Exception("modern reader layout mismatch");if(r.TotalVertices!=4||r.TotalTriangles!=2)throw new Exception("modern synthetic geometry count mismatch");if(r.XY.MinA<9.9||r.XY.MinB<19.9||r.XY.SpanA<99.9||r.XY.SpanB<49.9||r.XY.ThicknessRatio>0.0001)throw new Exception("modern synthetic transform/projection mismatch");return "ok";
    }

    public static string SelfTestModernReject(string tempDir){
        Directory.CreateDirectory(tempDir);string stem=Path.Combine(tempDir,"synthetic_modern_reject");MMGNifReport r=AnalyzeNif(BuildSyntheticModernNif(24u),stem);if(r.Success)throw new Exception("modern invalid AV-tail signature was promoted");bool seen=false;if(r.Warnings!=null)foreach(string w in r.Warnings)if(w!=null&&w.IndexOf("AV-tail signature mismatch",StringComparison.OrdinalIgnoreCase)>=0){seen=true;break;}if(!seen)throw new Exception("modern invalid AV-tail rejection evidence missing");return "ok";
    }

    // 20.2.5.22 profile: identical AV struct and one-byte marker, but no uint32 tag after it.
    static byte[] BuildSyntheticModern22Nif(byte markerByte){
        byte[] node,shape,geom;
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write((uint)0);w.Write((uint)0);w.Write(-1);w.Write((ushort)0x10);for(int i=0;i<3;i++)w.Write(0f);for(int i=0;i<9;i++)w.Write(i==0||i==4||i==8?1f:0f);w.Write(1f);w.Write((uint)0);w.Write(-1);w.Write(markerByte);w.Write((uint)1);w.Write(1);node=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write((uint)1);w.Write((uint)0);w.Write(-1);w.Write((ushort)0x10);w.Write(10f);w.Write(20f);w.Write(0f);for(int i=0;i<9;i++)w.Write(i==0||i==4||i==8?1f:0f);w.Write(1f);w.Write((uint)0);w.Write(-1);w.Write(markerByte);w.Write(2);w.Write(-1);shape=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write(0);w.Write((ushort)4);w.Write((byte)0);w.Write((byte)0);w.Write((byte)1);float[,] v={{0,0,0},{100,0,0},{100,50,0},{0,50,0}};for(int i=0;i<4;i++){w.Write(v[i,0]);w.Write(v[i,1]);w.Write(v[i,2]);}w.Write((ushort)0);w.Write((byte)0);for(int i=0;i<4;i++)w.Write(0f);w.Write((byte)0);w.Write((ushort)0);w.Write(-1);w.Write((ushort)2);w.Write((uint)6);w.Write((byte)1);w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)2);w.Write((ushort)0);w.Write((ushort)2);w.Write((ushort)3);w.Write((ushort)0);geom=ms.ToArray();}
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            w.Write(Encoding.ASCII.GetBytes("Gamebryo File Format, Version 20.2.5.22\n"));w.Write(NIF_QQSPEED_20_2_5_22);w.Write((byte)1);w.Write((uint)0);w.Write((uint)3);w.Write((ushort)3);
            string[] types={"NiNode","NiTriShape","NiTriShapeData"};foreach(string x in types){byte[] b=Encoding.ASCII.GetBytes(x);w.Write((uint)b.Length);w.Write(b);}w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)2);w.Write((uint)node.Length);w.Write((uint)shape.Length);w.Write((uint)geom.Length);w.Write((uint)2);w.Write((uint)5);foreach(string x in new[]{"root","shape"}){byte[] b=Encoding.ASCII.GetBytes(x);w.Write((uint)b.Length);w.Write(b);}w.Write((uint)0);w.Write(node);w.Write(shape);w.Write(geom);return ms.ToArray();}
    }
    public static string SelfTestModern22(string tempDir){
        Directory.CreateDirectory(tempDir);string stem=Path.Combine(tempDir,"synthetic_modern22");MMGNifReport r=AnalyzeNif(BuildSyntheticModern22Nif(0),stem);
        if(!r.Success)throw new Exception("20.2.5.22 synthetic parse failed: "+r.Error);
        if(r.ReaderLayout!="qqspeed_20_2_5_22_av_marker_v1")throw new Exception("20.2.5.22 reader layout mismatch");
        if(r.TotalVertices!=4||r.TotalTriangles!=2)throw new Exception("20.2.5.22 synthetic geometry count mismatch");
        if(r.XY.MinA<9.9||r.XY.MinB<19.9||r.XY.SpanA<99.9||r.XY.SpanB<49.9||r.XY.ThicknessRatio>0.0001)throw new Exception("20.2.5.22 synthetic transform/projection mismatch");
        return "ok";
    }
    public static string SelfTestModern22Reject(string tempDir){
        Directory.CreateDirectory(tempDir);string stem=Path.Combine(tempDir,"synthetic_modern22_reject");MMGNifReport r=AnalyzeNif(BuildSyntheticModern22Nif(0x7F),stem);
        if(r.Success)throw new Exception("20.2.5.22 invalid AV-marker signature was promoted");
        bool seen=false;if(r.Warnings!=null)foreach(string w in r.Warnings)if(w!=null&&w.IndexOf("20.2.5.22 AV-tail signature mismatch",StringComparison.OrdinalIgnoreCase)>=0){seen=true;break;}
        if(!seen)throw new Exception("20.2.5.22 invalid AV-marker rejection evidence missing");
        return "ok";
    }
}
"@


if(-not ('QQOfficialMinimapGeometryCore' -as [type])) {
    Write-Host '[1/4] 编译 Native Map NIF/VFS core...'
    Add-Type -TypeDefinition $cs -Language CSharp
}
Write-Host '[2/4] 扫描 VFS 并提取官方 map.nif...'
$nodes=@([QQOfficialMinimapGeometryCore]::ParseAllMapNodes($GamePath))
$exact=('Map\Common Map\Map{0}\map.nif' -f $MapId)
$cand=@($nodes|Where-Object {$_.FullPath -ieq $exact -and $_.Type -eq 1})
if($cand.Count-eq0){throw ('Map'+$MapId+' 官方 map.nif 不存在。')}
$best=$null
# native_map_parse_diagnostic_collection_v2: use a plain PowerShell object[] on WinPS 5.1.
# Do not use List[object] + @($list) here; the unsupported-map branch must never be masked by binder/serialization errors.
$parseDiagnostics=@()
foreach($n in $cand){
    $bytes=[QQOfficialMinimapGeometryCore]::ExtractDecoded($n)
    if($null-eq$bytes){
        $parseDiagnostics += [pscustomobject][ordered]@{source_vfs=[string]$n.Vfs;source_path=[string]$n.FullPath;sha256=$null;decoded=$false;success=$false;error='VFS payload decode failed';header=$null;version_hex=$null;user_version=$null;user_version2=$null;reader_layout=$null;num_blocks=$null;block_types=[string[]]@();shape_blocks=0;decoded_shapes=0;hidden_shapes=0;vertices=0;triangles=0;best_projection=$null;warnings=[string[]]@()}
        continue
    }
    $sha=[QQOfficialMinimapGeometryCore]::Sha256($bytes)
    $stem=Join-Path $nativeRoot ('official_map_'+$sha.Substring(0,8))
    $report=[QQOfficialMinimapGeometryCore]::AnalyzeNif($bytes,$stem)
    $diag=[pscustomobject][ordered]@{
        source_vfs=[string]$n.Vfs;source_path=[string]$n.FullPath;sha256=$sha;decoded=$true;success=[bool]$report.Success;error=[string]$report.Error
        header=[string]$report.HeaderString;version_hex=$(if([uint32]$report.Version-ne0){('0x{0:X8}' -f [uint32]$report.Version)}else{$null});user_version=[uint32]$report.UserVersion;user_version2=[uint32]$report.UserVersion2;reader_layout=[string]$report.ReaderLayout;num_blocks=[int]$report.NumBlocks
        block_types=[string[]]$report.BlockTypes;shape_blocks=[int]$report.ShapeBlocks;decoded_shapes=[int]$report.DecodedShapes;hidden_shapes=[int]$report.HiddenShapes;vertices=[int]$report.TotalVertices;triangles=[int]$report.TotalTriangles;best_projection=[string]$report.BestProjection;warnings=[string[]]$report.Warnings
    }
    $parseDiagnostics += $diag
    if(-not[bool]$report.Success){continue}
    $row=[pscustomobject]@{node=$n;bytes=$bytes;sha=$sha;report=$report}
    if($null-eq$best -or [int]$report.TotalTriangles -gt [int]$best.report.TotalTriangles){$best=$row}
}
if($null-eq$best){
    $diagRoot=Join-Path $dataDir 'Diagnostics\NativeMap'
    New-Item -ItemType Directory -Force -Path $diagRoot|Out-Null
    $diagPath=Join-Path $diagRoot ('Map'+$MapId+'_parse.json')

    # Console evidence comes first. Diagnostic serialization must never hide the actual unsupported NIF evidence.
    Write-Host ('[DIAG] Map'+$MapId+' map.nif candidates='+$cand.Count+' · no production geometry promoted')
    foreach($d in $parseDiagnostics){
        Write-Host ('  candidate vfs='+[string]$d.source_vfs+' sha='+$(if($d.sha256){([string]$d.sha256).Substring(0,12)}else{'decode-failed'})+' header='+[string]$d.header+' version='+[string]$d.version_hex+' user='+[string]$d.user_version+'/'+[string]$d.user_version2+' layout='+[string]$d.reader_layout+' blocks='+[string]$d.num_blocks+' shapeBlocks='+[string]$d.shape_blocks+' decoded='+[string]$d.decoded_shapes+' hidden='+[string]$d.hidden_shapes+' triangles='+[string]$d.triangles+' error='+[string]$d.error)
        if($null-ne$d.block_types -and [int]$d.block_types.Count-gt0){Write-Host ('    block-types: '+([string[]]$d.block_types -join ', '))}
        if($null-ne$d.warnings){foreach($w in ($d.warnings|Select-Object -First 8)){Write-Host ('    warning: '+[string]$w)}}
        if($null-ne$d.warnings -and [int]$d.warnings.Count-gt8){Write-Host ('    warning: ... +'+([int]$d.warnings.Count-8)+' more (see diagnostic JSON)')}
    }

    $diagDoc=[ordered]@{schema_version=1;contract='native_map_parse_diagnostic_v1';resource_map_id=$MapId;source_path=$exact;candidate_count=$cand.Count;parser_scope='NiTriShape/NiTriStrips + NiTriShapeData/NiTriStripsData';reader_profiles='standard_gamebryo_av_v1 + verified qqspeed_20_2_5_22_av_marker_v1 + verified qqspeed_20_2_5_23_av_tail_v1';production_promoted=$false;diagnostic_collection='powershell_object_array_v2';candidates=[object[]]$parseDiagnostics;generated_at=(Get-Date).ToString('o')}
    try {
        Write-Utf8Bom $diagPath ($diagDoc|ConvertTo-Json -Depth 12)
        Write-Host ('  diagnostic: '+$diagPath)
    } catch {
        Write-Warning ('NativeMap diagnostic serialization failed, but parser evidence above is preserved: '+$_.Exception.GetType().FullName+' · '+$_.Exception.Message)
    }
    throw ('Map'+$MapId+' map.nif 存在，但当前 Native Map parser 无法安全解析为生产可见几何；已输出格式证据，不使用轨迹底图替代。')
}
if(-not([string]$best.report.BestProjection -like 'XY*')){throw ('Map'+$MapId+' map.nif 主投影不是 XY；拒绝生产 promotion。')}

Write-Host '[3/4] 固化官方矢量地图与世界坐标变换...'
$nifPath=Join-Path $nativeRoot 'official_map.nif'
$svgPath=Join-Path $nativeRoot 'official_map.svg'
[IO.File]::WriteAllBytes($nifPath,[byte[]]$best.bytes)
Copy-Item -LiteralPath ([string]$best.report.XY.SvgPath) -Destination $svgPath -Force
$xy=$best.report.XY
$W=1200.0;$H=1200.0;$pad=35.0
$spanX=[Math]::Max(0.000001,[double]$xy.SpanA);$spanY=[Math]::Max(0.000001,[double]$xy.SpanB)
$scale=[Math]::Min(($W-2*$pad)/$spanX,($H-2*$pad)/$spanY)
$offsetX=($W-$spanX*$scale)/2.0;$offsetY=($H-$spanY*$scale)/2.0
$meta=[ordered]@{
    schema_version=1;contract='native_map_v1';architecture='native_first_v1';official_source=$true
    resource_map_id=$MapId;source_path=$exact;source_vfs=[string]$best.node.Vfs;geometry_sha256=[string]$best.sha;nif_version=('0x{0:X8}' -f [uint32]$best.report.Version);nif_reader_layout=[string]$best.report.ReaderLayout
    map_model='official_map.nif';vector_minimap='official_map.svg';minimap='official_map.svg';minimap_renderer='gamebryo_map_nif_xy_v3_clean_surface'
    geometry=[ordered]@{shapes=[int]$best.report.DecodedShapes;vertices=[int]$best.report.TotalVertices;triangles=[int]$best.report.TotalTriangles;best_projection=[string]$best.report.BestProjection;thickness_ratio=[double]$best.report.BestThicknessRatio;world_min_x=[double]$xy.MinA;world_max_x=[double]$xy.MaxA;world_min_y=[double]$xy.MinB;world_max_y=[double]$xy.MaxB;world_min_z=[double]$xy.MinDepth;world_max_z=[double]$xy.MaxDepth}
    render_transform=[ordered]@{canvas_width=1200;canvas_height=1200;world_min_x=[double]$xy.MinA;world_min_y=[double]$xy.MinB;world_max_x=[double]$xy.MaxA;world_max_y=[double]$xy.MaxB;scale=$scale;offset_x=$offsetX;offset_y=$offsetY;y_inverted=$true}
    validation=[ordered]@{map37_direct_xy_alignment_reference='100% inside / p95 0.000m';rule='Official map.nif world XY is authoritative map geometry. Reader may apply only file-native AV transforms validated from NIF blocks. No replay-fit, external rotation/scale/translation, reference-line or trajectory-derived basemap is permitted.'}
    dynamic_scene=[ordered]@{status='pending_labeled_dynamic_scene_replay';static_geometry_authoritative=$true}
    generated_at=(Get-Date).ToString('o')
}
Write-Utf8Bom $metadataPath ($meta|ConvertTo-Json -Depth 10)
Write-Host '[4/4] 完成。'
Write-Host ('[OK] Native Map: Map'+$MapId+' shapes='+$meta.geometry.shapes+' vertices='+$meta.geometry.vertices+' triangles='+$meta.geometry.triangles+' source=map.nif')
Write-Host ('     svg: '+$svgPath)
exit 0
