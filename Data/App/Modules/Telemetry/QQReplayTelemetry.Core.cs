using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;


public sealed class QQReplayPhysicalFastRow
{
    public double time;
    public double time_s;
    public double x, y, z;
    public double speed;
    public double speed_raw;
    public string speed_source;
    public double direct_speed;
    public double derived_speed;
    public double direct_vx, direct_vy, direct_vz;
    public double yaw;
    public double slip;
    public double raw_slip;
    public double distance;
    public bool pose_valid;
    public bool pose_break_before;
    public int? contact_state;
    public string contact_state_name;
    public bool? is_airborne;
    public int? lap_index;
    public double vehicle_forward_heading;
    public double vehicle_forward_heading_rad;
    public int?[] input_bool_candidate = new int?[6];
    public int? input_bool_candidate_60;
    public int? input_bool_candidate_61;
    public int? input_bool_candidate_62;
    public int? input_bool_candidate_63;
    public int? input_bool_candidate_64;
    public int? input_bool_candidate_65;
    public string source;
    public string source_stream;
    public object system_drift_state;
    public string system_drift_state_source;
    public bool nitro_active;
    public bool small_boost_active;
    public bool air_boost_active;
    public bool landing_boost_active;
    public bool map_propulsion_active;
    public bool small_boost_class_active;
    public string speed_effect_state_source;
}

public sealed class QQReplayPoseBreakResult
{
    public double[] edge_step;
    public bool[] edge_break;
}

public static class QQReplayPortable
{
    const int TIME_MAX_MS = 600000;
    const int MIN_STREAM_RECORDS = 80;
    const int STATE_REL_START = -96;
    const int STATE_REL_END = 96;

    // ---------------------------------------------------------------------------------------
    // Physical stream detector contract v2 - non-decreasing replay clock.
    //
    // A physical vehicle stream is a lane of fixed-stride records whose leading u32 is the
    // replay-native millisecond clock. v1 required every single step to satisfy 5 <= dt <= 100,
    // which silently shredded a networked opponent: its clock is quantised to the local frame
    // grid, so consecutive records legitimately repeat the same millisecond (measured
    // zero-step ratio 0.22..0.27 on the real 2026 corpus). Each 0 ms step ended the run, and
    // the surviving fragments fell below MIN_STREAM_RECORDS, so the second car vanished.
    //
    // v2 keeps the same lane/stride/record-count shape and only changes the clock contract:
    //   1. structural: a maximal run of 0 <= dt <= STEP_MAX_MS (never a backward step),
    //   2. clock:      the run itself must really advance (MIN_ELAPSED_MS), be driven by
    //                  forward steps (MIN_POSITIVE_RATIO) and not be a frozen or
    //                  constant-filled lane (MAX_ZERO_RATIO),
    //   3. geometry:   dense (every record, not a 48-point sample) quaternion validity,
    //                  finite/in-range position on every record, and a real movement span.
    // A lane whose clock never advances (time_start == time_end) fails step 2 and can never be
    // promoted to a vehicle, which is the fail-closed answer to the zero-time false candidate.
    // Every threshold below is derived from the real 2026 regression corpus, never from a
    // filename, a hash, an offset or a residue.
    // ---------------------------------------------------------------------------------------
    const string DETECTOR_CONTRACT = "physical_streams_v2_nondec_ts";
    const int STEP_MAX_MS = 100;             // largest tolerated single step (v1 bound, unchanged)
    const int MIN_ELAPSED_MS = 2000;         // corpus minimum observed stream elapsed = 3623 ms
    const double MIN_POSITIVE_RATIO = 0.30;  // corpus minimum observed forward-step ratio = 0.729
    const double MAX_ZERO_RATIO = 0.90;      // corpus maximum observed zero-step ratio = 0.271
    const double MIN_Q_VALID = 0.80;         // dense quaternion validity (v1 threshold, now dense)
    const double MIN_MOVEMENT_SPAN = 20.0;   // corpus minimum observed XY span = 34.7; placeholders < 2.5
    const double MAX_ABS_COORD = 100000.0;

    sealed class Profile
    {
        public string Name;
        public int Stride;
        public int QuatRel;
        public int PosRel;
        public int? DirectVelRel;
        public int? ContactStateRel;
        public int? LapIndexRel;
        public int? InputBoolCandidateStartRel;
        public string VehicleForwardAxisLocal;
        public Profile(string name, int stride, int quatRel, int posRel, int? directVelRel, int? contactStateRel, int? lapIndexRel, int? inputBoolCandidateStartRel, string vehicleForwardAxisLocal)
        {
            Name = name; Stride = stride; QuatRel = quatRel; PosRel = posRel; DirectVelRel = directVelRel;
            ContactStateRel = contactStateRel; LapIndexRel = lapIndexRel; InputBoolCandidateStartRel = inputBoolCandidateStartRel; VehicleForwardAxisLocal = vehicleForwardAxisLocal;
        }
    }

    sealed class StreamCandidate
    {
        public Profile P;
        public int Residue;
        public int StartIndex;
        public int EndIndex;
        public double Score;
        public double QValidFraction;
        public double MovementSpan;
        public uint T0;
        public uint T1;
        public int Records { get { return EndIndex - StartIndex + 1; } }
        public long StartByte { get { return (long)Residue + (long)StartIndex * P.Stride; } }
        public long EndByte { get { return (long)Residue + (long)EndIndex * P.Stride; } }
    }

    sealed class StateField
    {
        public int Rel;
        public List<int> Unique = new List<int>();
        public int Changes;
        public Dictionary<int, int> Counts = new Dictionary<int, int>();
    }

    sealed class Row
    {
        public int RecordIndex;
        public uint TimeMs;
        public double TimeS;
        public float Qx, Qy, Qz, Qw;
        public float X, Y, Z;
        public bool HasFileV;
        public float FileVx, FileVy, FileVz;
        public Dictionary<int, int> States = new Dictionary<int, int>();
        public int DtMs;
        public double YawRad, YawDeg;
        public double Vx, Vy, Vz, SpeedXY, Speed3D, Accel3D;
        public double MotionHeadingRad, SlipAngleRad, DistanceCumulative;
        public int? ContactState, LapIndex;
        public bool? IsAirborne;
        public byte?[] InputBoolCandidate = new byte?[6];
        public double? VehicleForwardHeadingRad;
    }

    static readonly Profile[] Profiles = new Profile[] {
        new Profile("2021", 141, 20, 36, null, null, null, null, null),
        new Profile("2025", 218, 16, 32, 44, null, null, null, null),
        // 2026 production schema v1: modern offsets below were promoted only after
        // source-guided probing plus four-replay cross-validation. Input 60..65 remains unnamed.
        new Profile("2026", QQReplaySchema2026.Stride, QQReplaySchema2026.QuaternionOffset, QQReplaySchema2026.PositionOffset,
            QQReplaySchema2026.LinearVelocityOffset, QQReplaySchema2026.ContactStateOffset, QQReplaySchema2026.LapIndexOffset,
            QQReplaySchema2026.InputBoolCandidateStart, QQReplaySchema2026.VehicleForwardAxisLocal),
    };

    // Stable primitive/kinematic contracts live in Core/ReplayCore.Contracts.cs.
    // Keep these wrappers so the extractor implementation can be refactored incrementally
    // without changing its internal call graph in the same release.
    static uint U32(byte[] d, int o) { return QQReplayBinary.U32(d, o); }
    static int I32(byte[] d, int o) { return QQReplayBinary.I32(d, o); }
    static float F32(byte[] d, int o) { return QQReplayBinary.F32(d, o); }
    static bool Finite(double x) { return QQReplayKinematics.Finite(x); }
    static double Hypot(double x, double y) { return QQReplayKinematics.Hypot(x, y); }
    static double WrapPi(double v) { return QQReplayKinematics.WrapPi(v); }
    static double QuatYaw(double qx, double qy, double qz, double qw) { return QQReplayKinematics.QuaternionYaw(qx, qy, qz, qw); }
    static double QuatMinusYHeading(double qx, double qy, double qz, double qw) { return QQReplayKinematics.VehicleForwardHeadingMinusY(qx, qy, qz, qw); }

    // The physical-stream detector contract identity. The telemetry driver writes this into the
    // raw physical cache descriptor and requires it on reuse, so a detector contract change can
    // never be masked by a previously written cache that still looks structurally valid.
    public static string PhysicalStreamDetectorContract { get { return DETECTOR_CONTRACT; } }

    // Emit only runs that already satisfy the clock contract, so an indefinite constant/zero lane
    // never reaches the (denser, more expensive) geometry validation.
    static List<int[]> FindRuns(byte[] data, int stride, int residue)
    {
        List<int[]> runs = new List<int[]>();
        int n = (data.Length - residue - 4) / stride + 1;
        if (n < MIN_STREAM_RECORDS) return runs;
        uint[] vals = new uint[n];
        for (int i=0; i<n; i++) vals[i] = U32(data, residue + i*stride);
        int runStart = -1;
        int pos = 0, zero = 0;
        for (int i=0; i<n-1; i++) {
            uint a=vals[i], b=vals[i+1];
            long diff = b >= a ? (long)b-a : -1;
            bool good = a < TIME_MAX_MS && b < TIME_MAX_MS && diff >= 0 && diff <= STEP_MAX_MS;
            if (good) {
                if (runStart < 0) { runStart = i; pos = 0; zero = 0; }
                if (diff > 0) pos++; else zero++;
            }
            if (!good && runStart >= 0) {
                EmitRunIfClockValid(runs, vals, runStart, i, pos, zero);
                runStart=-1;
            }
        }
        if (runStart >= 0) EmitRunIfClockValid(runs, vals, runStart, n-1, pos, zero);
        return runs;
    }

    static void EmitRunIfClockValid(List<int[]> runs, uint[] vals, int s, int e, int pos, int zero)
    {
        int records = e - s + 1;
        if (records < MIN_STREAM_RECORDS) return;
        long elapsed = (long)vals[e] - (long)vals[s];
        if (elapsed < MIN_ELAPSED_MS) return;
        int transitions = records - 1;
        if (pos + zero != transitions) return;
        if (pos < MIN_POSITIVE_RATIO * transitions) return;
        if (zero > MAX_ZERO_RATIO * transitions) return;
        runs.Add(new int[]{s, e, (int)vals[s], (int)vals[e]});
    }

    // Dense validation over EVERY record of the run. v1 sampled 48 points, which was enough for a
    // clean 60 Hz stream but let a mostly-constant lane through on a lucky subsample.
    static bool ValidateRun(byte[] data, Profile p, int residue, int s, int e, out double score, out double qFraction, out double span)
    {
        score=qFraction=span=0.0;
        int count=e-s+1;
        if (count < MIN_STREAM_RECORDS) return false;
        int qOk=0, valid=0, posBad=0;
        bool have=false;
        float minx=0.0f, maxx=0.0f, miny=0.0f, maxy=0.0f;
        for (int idx=s; idx<=e; idx++) {
            int to = residue + idx*p.Stride;
            int qo=to+p.QuatRel, po=to+p.PosRel;
            if (qo<0 || po<0 || qo+16>data.Length || po+12>data.Length) return false;
            float qx=F32(data,qo), qy=F32(data,qo+4), qz=F32(data,qo+8), qw=F32(data,qo+12);
            float x=F32(data,po), y=F32(data,po+4), z=F32(data,po+8);
            if (!Finite(qx)||!Finite(qy)||!Finite(qz)||!Finite(qw)) continue;
            valid++;
            double qn=Math.Sqrt((double)qx*qx+(double)qy*qy+(double)qz*qz+(double)qw*qw);
            if (qn>0.80 && qn<1.20) qOk++;
            if (!Finite(x)||!Finite(y)||!Finite(z) || Math.Max(Math.Abs(x),Math.Max(Math.Abs(y),Math.Abs(z)))>MAX_ABS_COORD) { posBad++; continue; }
            if (!have) { minx=maxx=x; miny=maxy=y; have=true; }
            else { if(x<minx)minx=x; if(x>maxx)maxx=x; if(y<miny)miny=y; if(y>maxy)maxy=y; }
        }
        if (valid < MIN_STREAM_RECORDS || !have) return false;
        if (posBad > 0) return false;
        qFraction=(double)qOk/valid;
        if (qFraction<MIN_Q_VALID) return false;
        span=Hypot(maxx-minx,maxy-miny);
        if (span<=MIN_MOVEMENT_SPAN) return false;
        score=3.0*qFraction + 2.0*Math.Min(span,1.0) + 1.0 + Math.Min(count/10000.0,1.0);
        return true;
    }

    static bool CandidatesSameTrajectory(byte[] data, StreamCandidate a, StreamCandidate b)
    {
        if (a.P.Name != b.P.Name) return false;
        double durA = Math.Max(1.0, (double)a.T1 - a.T0);
        double durB = Math.Max(1.0, (double)b.T1 - b.T0);
        double maxDur = Math.Max(durA, durB);
        if (Math.Abs(durA-durB) > Math.Max(250.0, 0.03*maxDur)) return false;

        double hzA = Math.Max(0.0, (a.Records-1) * 1000.0 / durA);
        double hzB = Math.Max(0.0, (b.Records-1) * 1000.0 / durB);
        if (Math.Max(hzA,hzB) > 0.0 && Math.Abs(hzA-hzB) > Math.Max(1.0,0.05*Math.Max(hzA,hzB))) return false;

        const int N = 9;
        double sum = 0.0, maxD = 0.0;
        for (int i=0;i<N;i++) {
            int ia = a.StartIndex + (int)Math.Round(i*(a.Records-1.0)/(N-1.0));
            int ib = b.StartIndex + (int)Math.Round(i*(b.Records-1.0)/(N-1.0));
            int oa = a.Residue + ia*a.P.Stride + a.P.PosRel;
            int ob = b.Residue + ib*b.P.Stride + b.P.PosRel;
            if (oa<0 || ob<0 || oa+12>data.Length || ob+12>data.Length) return false;

            double ax=F32(data,oa), ay=F32(data,oa+4), az=F32(data,oa+8);
            double bx=F32(data,ob), by=F32(data,ob+4), bz=F32(data,ob+8);
            if(!Finite(ax)||!Finite(ay)||!Finite(az)||!Finite(bx)||!Finite(by)||!Finite(bz)) return false;
            double dx=ax-bx,dy=ay-by,dz=az-bz;
            double d=Math.Sqrt(dx*dx+dy*dy+dz*dz);
            sum+=d; if(d>maxD)maxD=d;
        }
        double avg=sum/N;
        return avg < 0.20 && maxD < 0.75;
    }

    static List<StreamCandidate> DetectStreams(byte[] data, out string profileName)
    {
        List<StreamCandidate> all=new List<StreamCandidate>();
        foreach (Profile p in Profiles) {
            for (int residue=0; residue<p.Stride; residue++) {
                foreach (int[] r in FindRuns(data,p.Stride,residue)) {
                    double sc,qf,sp;
                    if (!ValidateRun(data,p,residue,r[0],r[1],out sc,out qf,out sp)) continue;
                    StreamCandidate c=new StreamCandidate();
                    c.P=p; c.Residue=residue; c.StartIndex=r[0]; c.EndIndex=r[1]; c.Score=sc; c.QValidFraction=qf; c.MovementSpan=sp; c.T0=(uint)r[2]; c.T1=(uint)r[3];
                    all.Add(c);
                }
            }
        }
        if (all.Count==0) throw new Exception("未识别到已支持的车辆数据流；可能是新的回放格式。");
        all.Sort(delegate(StreamCandidate a, StreamCandidate b) {
            int x=b.Score.CompareTo(a.Score); return x!=0 ? x : b.Records.CompareTo(a.Records);
        });
        Profile best=all[0].P;
        profileName=best.Name;
        List<StreamCandidate> same=all.Where(c=>c.P.Name==best.Name && c.QValidFraction>=MIN_Q_VALID).ToList();
        same.Sort(delegate(StreamCandidate a, StreamCandidate b) { int x=a.StartByte.CompareTo(b.StartByte); return x!=0 ? x : b.Records.CompareTo(a.Records); });
        // Modern 230-byte records also contain a second precise-pose block beginning
        // 137 bytes after the record start (its quaternion/position land at +145/+161).
        // On some maps the bytes at +137 happen to form short monotonic timer runs, so the
        // generic detector can falsely rediscover that embedded pose as another "vehicle".
        // Reject only candidates fully contained in a larger 2026 stream at this exact
        // native subrecord phase; this is a record-layout alias, not a second actor.
        List<StreamCandidate> aliasFiltered=new List<StreamCandidate>();
        foreach (StreamCandidate c in same) {
            bool embeddedAlias=false;
            if (c.P.Name=="2026") {
                foreach (StreamCandidate parent in same) {
                    if (Object.ReferenceEquals(c,parent) || parent.P.Name!="2026" || parent.Records<=c.Records) continue;
                    if (parent.StartByte>c.StartByte || parent.EndByte<c.EndByte) continue;
                    long phase=(c.StartByte-parent.StartByte)%parent.P.Stride;
                    if (phase<0) phase+=parent.P.Stride;
                    if (phase==137) { embeddedAlias=true; break; }
                }
            }
            if (!embeddedAlias) aliasFiltered.Add(c);
        }

        List<StreamCandidate> kept=new List<StreamCandidate>();
        foreach (StreamCandidate c in aliasFiltered) {
            bool duplicate=false;
            foreach (StreamCandidate k in kept) {
                long overlap=Math.Max(0,Math.Min(c.EndByte,k.EndByte)-Math.Max(c.StartByte,k.StartByte));
                long shorter=Math.Max(1,Math.Min(c.EndByte-c.StartByte,k.EndByte-k.StartByte));
                // Broad byte-range overlap alone is NOT enough to call two candidates duplicates.
                // Two cars can be interleaved in the same file region at different residues.
                // Only collapse them when their trajectories are effectively identical.
                if ((double)overlap/shorter>0.95 && CandidatesSameTrajectory(data,c,k)) { duplicate=true; break; }
            }
            if (!duplicate) kept.Add(c);
        }
        kept.Sort(delegate(StreamCandidate a, StreamCandidate b) { return a.StartByte.CompareTo(b.StartByte); });
        return kept;
    }

    static List<StateField> DiscoverStates(byte[] data, StreamCandidate c)
    {
        List<StateField> result=new List<StateField>();
        int n=c.Records;
        for (int rel=STATE_REL_START; rel<=STATE_REL_END; rel++) {
            Dictionary<int,int> counts=new Dictionary<int,int>();
            int changes=0, prev=-1; bool ok=true;
            for (int idx=c.StartIndex; idx<=c.EndIndex; idx++) {
                long off=(long)c.Residue+(long)idx*c.P.Stride+rel;
                if (off<0 || off>=data.Length) { ok=false; break; }
                int v=data[(int)off];
                if (v>7) { ok=false; break; }
                int old; counts.TryGetValue(v,out old); counts[v]=old+1;
                if (prev>=0 && v!=prev) changes++;
                prev=v;
                if (counts.Count>8) { ok=false; break; }
            }
            if (!ok || counts.Count<2 || counts.Count>8) continue;
            int maxChanges=Math.Min(2500,Math.Max(8,n/2));
            if (changes<8 || changes>maxChanges) continue;
            StateField sf=new StateField(); sf.Rel=rel; sf.Changes=changes; sf.Unique=counts.Keys.OrderBy(x=>x).ToList(); sf.Counts=counts; result.Add(sf);
        }
        return result;
    }

    static double[] Derivative(double[] vals, double[] times)
    {
        int n=vals.Length; double[] o=new double[n];
        if (n==0) return o; if (n==1) return o;
        double dt=times[1]-times[0]; o[0]=dt>0?(vals[1]-vals[0])/dt:0;
        for (int i=1;i<n-1;i++) { dt=times[i+1]-times[i-1]; o[i]=dt>0?(vals[i+1]-vals[i-1])/dt:0; }
        dt=times[n-1]-times[n-2]; o[n-1]=dt>0?(vals[n-1]-vals[n-2])/dt:0;
        return o;
    }

    static List<Row> ExtractRows(byte[] data, StreamCandidate c, bool discoverStateFields, out List<StateField> states)
    {
        states=discoverStateFields?DiscoverStates(data,c):new List<StateField>();
        List<Row> rows=new List<Row>();
        int rec=0;
        for (int idx=c.StartIndex;idx<=c.EndIndex;idx++,rec++) {
            int to=c.Residue+idx*c.P.Stride;
            Row r=new Row(); r.RecordIndex=rec; r.TimeMs=U32(data,to); r.TimeS=r.TimeMs/1000.0;
            int qo=to+c.P.QuatRel, po=to+c.P.PosRel;
            r.Qx=F32(data,qo);r.Qy=F32(data,qo+4);r.Qz=F32(data,qo+8);r.Qw=F32(data,qo+12);
            r.X=F32(data,po);r.Y=F32(data,po+4);r.Z=F32(data,po+8);
            if (c.P.DirectVelRel.HasValue) {
                int vo=to+c.P.DirectVelRel.Value;
                if (vo>=0 && vo+12<=data.Length) { r.FileVx=F32(data,vo);r.FileVy=F32(data,vo+4);r.FileVz=F32(data,vo+8); r.HasFileV=Finite(r.FileVx)&&Finite(r.FileVy)&&Finite(r.FileVz); }
            }
            if (c.P.ContactStateRel.HasValue) {
                int o=to+c.P.ContactStateRel.Value;
                if (o>=0 && o+4<=data.Length) {
                    int v=I32(data,o); r.ContactState=v;
                    if (v==0) r.IsAirborne=true; else if (v==5) r.IsAirborne=false; else r.IsAirborne=null;
                }
            }
            if (c.P.LapIndexRel.HasValue) { int o=to+c.P.LapIndexRel.Value; if (o>=0 && o+4<=data.Length) r.LapIndex=I32(data,o); }
            if (c.P.InputBoolCandidateStartRel.HasValue) {
                int o=to+c.P.InputBoolCandidateStartRel.Value;
                for (int k=0;k<6;k++) if (o+k>=0 && o+k<data.Length) r.InputBoolCandidate[k]=data[o+k];
            }
            if (c.P.VehicleForwardAxisLocal=="-Y") r.VehicleForwardHeadingRad=QuatMinusYHeading(r.Qx,r.Qy,r.Qz,r.Qw);
            foreach(StateField sf in states) { int off=to+sf.Rel; if (off>=0&&off<data.Length) r.States[sf.Rel]=data[off]; }
            rows.Add(r);
        }
        int n=rows.Count; double[] t=new double[n],x=new double[n],y=new double[n],z=new double[n];
        for(int i=0;i<n;i++){t[i]=rows[i].TimeS;x[i]=rows[i].X;y[i]=rows[i].Y;z[i]=rows[i].Z;}
        double[] vx=Derivative(x,t),vy=Derivative(y,t),vz=Derivative(z,t),spd=new double[n];
        for(int i=0;i<n;i++) spd[i]=Math.Sqrt(vx[i]*vx[i]+vy[i]*vy[i]+vz[i]*vz[i]);
        double[] acc=Derivative(spd,t); double cum=0; double px=0,py=0,pz=0;
        for(int i=0;i<n;i++) {
            Row r=rows[i]; r.DtMs=i==0?0:(int)r.TimeMs-(int)rows[i-1].TimeMs;
            r.YawRad=QuatYaw(r.Qx,r.Qy,r.Qz,r.Qw); r.YawDeg=r.YawRad*180.0/Math.PI;
            r.Vx=vx[i];r.Vy=vy[i];r.Vz=vz[i];r.SpeedXY=Hypot(vx[i],vy[i]);r.Speed3D=spd[i];r.Accel3D=acc[i];
            r.MotionHeadingRad=r.SpeedXY>1e-9?Math.Atan2(vy[i],vx[i]):r.YawRad; r.SlipAngleRad=WrapPi(r.YawRad-r.MotionHeadingRad);
            if(i>0){double dx=r.X-px,dy=r.Y-py,dz=r.Z-pz;cum+=Math.Sqrt(dx*dx+dy*dy+dz*dz);} r.DistanceCumulative=cum; px=r.X;py=r.Y;pz=r.Z;
        }
        return rows;
    }

    static string Csv(string s) { if(s==null)return ""; if(s.IndexOfAny(new char[]{',','\"','\r','\n'})>=0)return "\""+s.Replace("\"","\"\"")+"\""; return s; }
    static string D(double v){return v.ToString("R",CultureInfo.InvariantCulture);} static string F(float v){return v.ToString("R",CultureInfo.InvariantCulture);}

    static double NormalizeRawSlip(double raw)
    {
        if (Double.IsNaN(raw) || Double.IsInfinity(raw)) return 0.0;
        double mag=Math.Abs(Math.Abs(raw)-(Math.PI/2.0));
        if (mag>(Math.PI/2.0)) mag=Math.PI/2.0;
        return raw<0 ? -mag : mag;
    }

    static void WriteFastBin(string path, List<Row> rows)
    {
        using(FileStream fs=new FileStream(path,FileMode.Create,FileAccess.Write,FileShare.Read))
        using(BinaryWriter w=new BinaryWriter(fs,new UTF8Encoding(false))) {
            w.Write(new byte[]{0x51,0x51,0x50,0x46,0x41,0x53,0x54,0x31}); // QQPFAST1
            w.Write(1);
            w.Write(rows.Count);
            foreach(Row r in rows) {
                w.Write(r.TimeS); w.Write((double)r.X); w.Write((double)r.Y); w.Write((double)r.Z);
                w.Write(r.Speed3D);
                w.Write(r.HasFileV);
                w.Write(r.HasFileV?(double)r.FileVx:Double.NaN); w.Write(r.HasFileV?(double)r.FileVy:Double.NaN); w.Write(r.HasFileV?(double)r.FileVz:Double.NaN);
                w.Write(r.YawRad); w.Write(r.SlipAngleRad);
                w.Write(r.ContactState.HasValue?r.ContactState.Value:Int32.MinValue);
                w.Write((byte)(r.IsAirborne.HasValue?(r.IsAirborne.Value?1:0):255));
                w.Write(r.LapIndex.HasValue?r.LapIndex.Value:Int32.MinValue);
                w.Write(r.VehicleForwardHeadingRad.HasValue?r.VehicleForwardHeadingRad.Value:Double.NaN);
                for(int k=0;k<6;k++) w.Write((byte)(r.InputBoolCandidate[k].HasValue?r.InputBoolCandidate[k].Value:255));
            }
        }
    }

    public static bool ValidateFastBin(string path)
    {
        try {
            using(FileStream fs=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
            using(BinaryReader r=new BinaryReader(fs,new UTF8Encoding(false))) {
                byte[] magic=r.ReadBytes(8); byte[] expected=new byte[]{0x51,0x51,0x50,0x46,0x41,0x53,0x54,0x31};
                if(magic.Length!=8 || !magic.SequenceEqual(expected)) return false;
                int version=r.ReadInt32(); if(version!=1) return false;
                int count=r.ReadInt32(); if(count<0 || count>2000000) return false;
                const long RowBytes=104;
                return fs.Length==16L+(long)count*RowBytes;
            }
        } catch { return false; }
    }

    public static QQReplayPhysicalFastRow[] LoadFastRows(string path, string profile, string streamId)
    {
        using(FileStream fs=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
        using(BinaryReader r=new BinaryReader(fs,new UTF8Encoding(false))) {
            byte[] magic=r.ReadBytes(8); byte[] expected=new byte[]{0x51,0x51,0x50,0x46,0x41,0x53,0x54,0x31};
            if(magic.Length!=8 || !magic.SequenceEqual(expected)) throw new InvalidDataException("QQReplay fast physical cache magic mismatch.");
            int version=r.ReadInt32(); if(version!=1) throw new InvalidDataException("Unsupported QQReplay fast physical cache version: "+version);
            int count=r.ReadInt32(); if(count<0 || count>2000000) throw new InvalidDataException("Invalid QQReplay fast physical row count: "+count);
            QQReplayPhysicalFastRow[] rows=new QQReplayPhysicalFastRow[count];
            bool modern=String.Equals(profile,"2026",StringComparison.OrdinalIgnoreCase);
            for(int i=0;i<count;i++) {
                QQReplayPhysicalFastRow q=new QQReplayPhysicalFastRow();
                q.time=r.ReadDouble(); q.time_s=q.time; q.x=r.ReadDouble(); q.y=r.ReadDouble(); q.z=r.ReadDouble();
                q.derived_speed=r.ReadDouble(); bool hasFileV=r.ReadBoolean(); q.direct_vx=r.ReadDouble(); q.direct_vy=r.ReadDouble(); q.direct_vz=r.ReadDouble();
                q.direct_speed=hasFileV?Math.Sqrt(q.direct_vx*q.direct_vx+q.direct_vy*q.direct_vy+q.direct_vz*q.direct_vz):Double.NaN;
                bool directFinite=hasFileV && Finite(q.direct_speed) && Finite(q.direct_vx) && Finite(q.direct_vy) && Finite(q.direct_vz);
                q.speed_source=(modern && directFinite)?"replay_linear_velocity":"derived_position_velocity";
                q.speed=(modern && directFinite)?q.direct_speed:q.derived_speed; q.speed_raw=q.speed;
                q.yaw=r.ReadDouble(); q.raw_slip=r.ReadDouble(); q.slip=NormalizeRawSlip(q.raw_slip);
                int contact=r.ReadInt32(); q.contact_state=contact==Int32.MinValue?(int?)null:contact; q.contact_state_name=q.contact_state.HasValue?QQReplaySchema2026.ContactStateName(q.contact_state.Value):"";
                byte air=r.ReadByte(); q.is_airborne=air==255?(bool?)null:(air==1);
                int lap=r.ReadInt32(); q.lap_index=lap==Int32.MinValue?(int?)null:lap;
                q.vehicle_forward_heading=r.ReadDouble(); q.vehicle_forward_heading_rad=q.vehicle_forward_heading;
                for(int k=0;k<6;k++){byte b=r.ReadByte();q.input_bool_candidate[k]=b==255?(int?)null:(int)b;}
                q.input_bool_candidate_60=q.input_bool_candidate[0]; q.input_bool_candidate_61=q.input_bool_candidate[1]; q.input_bool_candidate_62=q.input_bool_candidate[2]; q.input_bool_candidate_63=q.input_bool_candidate[3]; q.input_bool_candidate_64=q.input_bool_candidate[4]; q.input_bool_candidate_65=q.input_bool_candidate[5];
                q.source=streamId; q.source_stream=streamId; q.pose_valid=true; q.pose_break_before=false; q.distance=0.0;
                q.system_drift_state="unknown"; q.system_drift_state_source="unresolved_not_found";
                q.nitro_active=false; q.small_boost_active=false; q.air_boost_active=false; q.landing_boost_active=false; q.map_propulsion_active=false; q.small_boost_class_active=false; q.speed_effect_state_source="replay_native_action_object_speed_effect_table_v2";
                rows[i]=q;
            }
            if(fs.Position!=fs.Length) throw new InvalidDataException("QQReplay fast physical cache has trailing bytes.");
            return rows;
        }
    }

    public static QQReplayPoseBreakResult DetectPoseBreaks(QQReplayPhysicalFastRow[] rows)
    {
        QQReplayPoseBreakResult result=new QQReplayPoseBreakResult(); int n=rows==null?0:rows.Length;
        result.edge_step=new double[n]; result.edge_break=new bool[n]; if(n<2)return result;
        for(int i=1;i<n;i++) { double dx=rows[i].x-rows[i-1].x,dy=rows[i].y-rows[i-1].y,dz=rows[i].z-rows[i-1].z; result.edge_step[i]=Math.Sqrt(dx*dx+dy*dy+dz*dz); }
        double[] near=new double[16];
        for(int i=1;i<n;i++) {
            int c=0,lo=Math.Max(1,i-8),hi=Math.Min(n-1,i+8);
            for(int j=lo;j<=hi;j++) { if(Math.Abs(j-i)<=1)continue; double v=result.edge_step[j]; if(v>0.000001 && Finite(v))near[c++]=v; }
            double localStep=0.0;
            if(c>0){Array.Sort(near,0,c); localStep=(c%2==1)?near[c/2]:(near[c/2-1]+near[c/2])/2.0;}
            double yawJump=Math.Abs(WrapPi(rows[i].yaw-rows[i-1].yaw)); double soft=Math.Max(1.25,5.0*localStep),hard=Math.Max(2.0,8.0*localStep);
            if(result.edge_step[i]>soft && (yawJump>0.45 || result.edge_step[i]>hard)) result.edge_break[i]=true;
        }
        return result;
    }

    public static void WriteLogicalCsv(string path, QQReplayPhysicalFastRow[] rows)
    {
        using(StreamWriter w=new StreamWriter(path,false,new UTF8Encoding(true))) {
            string[] h=new string[]{"time_s","x","y","z","speed","speed_raw","speed_source","speed_direct","speed_derived","yaw","slip","distance","pose_valid","pose_break_before","contact_state","contact_state_name","is_airborne","lap_index","vehicle_forward_heading_rad","system_drift_state","system_drift_state_source","input_bool_candidate_60","input_bool_candidate_61","input_bool_candidate_62","input_bool_candidate_63","input_bool_candidate_64","input_bool_candidate_65","source_stream","nitro_active","small_boost_active","air_boost_active","landing_boost_active","map_propulsion_active","small_boost_class_active","speed_effect_state_source"};
            w.WriteLine(String.Join(",",h));
            foreach(QQReplayPhysicalFastRow q in rows) {
                List<string> a=new List<string>();
                a.Add(D(q.time_s));a.Add(D(q.x));a.Add(D(q.y));a.Add(D(q.z));a.Add(D(q.speed));a.Add(D(q.speed_raw));a.Add(Csv(q.speed_source));a.Add(Finite(q.direct_speed)?D(q.direct_speed):"");a.Add(Finite(q.derived_speed)?D(q.derived_speed):"");a.Add(D(q.yaw));a.Add(D(q.slip));a.Add(D(q.distance));a.Add(q.pose_valid?"True":"False");a.Add(q.pose_break_before?"True":"False");
                a.Add(q.contact_state.HasValue?q.contact_state.Value.ToString(CultureInfo.InvariantCulture):"");a.Add(Csv(q.contact_state_name));a.Add(q.is_airborne.HasValue?(q.is_airborne.Value?"True":"False"):"");a.Add(q.lap_index.HasValue?q.lap_index.Value.ToString(CultureInfo.InvariantCulture):"");a.Add(Finite(q.vehicle_forward_heading_rad)?D(q.vehicle_forward_heading_rad):"");
                a.Add(Csv(q.system_drift_state==null?"":Convert.ToString(q.system_drift_state,CultureInfo.InvariantCulture)));a.Add(Csv(q.system_drift_state_source));
                for(int k=0;k<6;k++)a.Add(q.input_bool_candidate[k].HasValue?q.input_bool_candidate[k].Value.ToString(CultureInfo.InvariantCulture):"");
                a.Add(Csv(q.source_stream));a.Add(q.nitro_active?"True":"False");a.Add(q.small_boost_active?"True":"False");a.Add(q.air_boost_active?"True":"False");a.Add(q.landing_boost_active?"True":"False");a.Add(q.map_propulsion_active?"True":"False");a.Add(q.small_boost_class_active?"True":"False");a.Add(Csv(q.speed_effect_state_source));
                w.WriteLine(String.Join(",",a.ToArray()));
            }
        }
    }

    static void WriteCsv(string path, List<Row> rows, List<StateField> states)
    {
        using(StreamWriter w=new StreamWriter(path,false,new UTF8Encoding(true))) {
            List<string> h=new List<string>(new string[]{"record_index","time_ms","time_s","qx","qy","qz","qw","x","y","z","file_vx","file_vy","file_vz"});
            foreach(StateField sf in states)h.Add("state_rel_"+(sf.Rel>=0?"+":"")+sf.Rel.ToString(CultureInfo.InvariantCulture));
            h.AddRange(new string[]{"dt_ms","yaw_rad","yaw_deg","derived_vx","derived_vy","derived_vz","speed_xy","speed_3d","accel_3d","motion_heading_rad","slip_angle_rad","distance_cumulative"});
            h.AddRange(new string[]{"contact_state","contact_state_name","is_airborne","lap_index","vehicle_forward_heading_rad","vehicle_forward_heading_deg","input_bool_candidate_60","input_bool_candidate_61","input_bool_candidate_62","input_bool_candidate_63","input_bool_candidate_64","input_bool_candidate_65"});
            w.WriteLine(String.Join(",",h.Select(Csv).ToArray()));
            foreach(Row r in rows) {
                List<string> a=new List<string>(); a.Add(r.RecordIndex.ToString());a.Add(r.TimeMs.ToString());a.Add(D(r.TimeS));a.Add(F(r.Qx));a.Add(F(r.Qy));a.Add(F(r.Qz));a.Add(F(r.Qw));a.Add(F(r.X));a.Add(F(r.Y));a.Add(F(r.Z));
                if(r.HasFileV){a.Add(F(r.FileVx));a.Add(F(r.FileVy));a.Add(F(r.FileVz));}else{a.Add("");a.Add("");a.Add("");}
                foreach(StateField sf in states){int v; a.Add(r.States.TryGetValue(sf.Rel,out v)?v.ToString():"");}
                a.Add(r.DtMs.ToString());a.Add(D(r.YawRad));a.Add(D(r.YawDeg));a.Add(D(r.Vx));a.Add(D(r.Vy));a.Add(D(r.Vz));a.Add(D(r.SpeedXY));a.Add(D(r.Speed3D));a.Add(D(r.Accel3D));a.Add(D(r.MotionHeadingRad));a.Add(D(r.SlipAngleRad));a.Add(D(r.DistanceCumulative));
                a.Add(r.ContactState.HasValue?r.ContactState.Value.ToString(CultureInfo.InvariantCulture):"");
                a.Add(r.ContactState.HasValue?QQReplaySchema2026.ContactStateName(r.ContactState.Value):"");
                a.Add(r.IsAirborne.HasValue?(r.IsAirborne.Value?"true":"false"):"");
                a.Add(r.LapIndex.HasValue?r.LapIndex.Value.ToString(CultureInfo.InvariantCulture):"");
                a.Add(r.VehicleForwardHeadingRad.HasValue?D(r.VehicleForwardHeadingRad.Value):"");
                a.Add(r.VehicleForwardHeadingRad.HasValue?D(r.VehicleForwardHeadingRad.Value*180.0/Math.PI):"");
                for(int k=0;k<6;k++) a.Add(r.InputBoolCandidate[k].HasValue?r.InputBoolCandidate[k].Value.ToString(CultureInfo.InvariantCulture):"");
                w.WriteLine(String.Join(",",a.Select(Csv).ToArray()));
            }
        }
    }

    static string JsonEscape(string s) { if(s==null)return ""; return s.Replace("\\","\\\\").Replace("\"","\\\"").Replace("\r","\\r").Replace("\n","\\n"); }
    static string SafeMapHint(string path)
    {
        string stem=Path.GetFileNameWithoutExtension(path); int k=stem.IndexOf('-'); string s=(k>=0?stem.Substring(0,k):stem).Trim();
        char[] bad=Path.GetInvalidFileNameChars(); StringBuilder b=new StringBuilder(); foreach(char c in s){if(Array.IndexOf(bad,c)<0 && c!='\r'&&c!='\n'&&c!='\t')b.Append(c); if(b.Length>=48)break;} return b.Length>0?b.ToString():"unknown_map";
    }

    static void ExtractInternal(string[] inputs, string outRoot, bool writePhysicalCsv)
    {
        Directory.CreateDirectory(outRoot); List<string> manifestReplays=new List<string>();
        for(int ri=0;ri<inputs.Length;ri++) {
            string replayId="replay_"+(ri+1).ToString("000"); string repDir=Path.Combine(outRoot,replayId); Directory.CreateDirectory(repDir);
            byte[] data=File.ReadAllBytes(inputs[ri]); string profile; List<StreamCandidate> streams=DetectStreams(data,out profile);
            int primary=-1,maxRec=-1;for(int i=0;i<streams.Count;i++){if(streams[i].Records>maxRec){maxRec=streams[i].Records;primary=i;}}
            List<string> streamJson=new List<string>();
            for(int si=0;si<streams.Count;si++) {
                StreamCandidate c=streams[si];
                List<StateField> sf; List<Row> rows=ExtractRows(data,c,writePhysicalCsv,out sf); string sid="stream_"+(si+1).ToString("00"); string csvRel=replayId+"/"+sid+".csv"; string fastRel=replayId+"/"+sid+".qpf";
                if(writePhysicalCsv) WriteCsv(Path.Combine(repDir,sid+".csv"),rows,sf);
                WriteFastBin(Path.Combine(repDir,sid+".qpf"),rows);
                double dur=rows.Count>=2?rows[rows.Count-1].TimeS-rows[0].TimeS:0; List<double> dts=new List<double>();for(int i=1;i<rows.Count;i++){double q=rows[i].TimeS-rows[i-1].TimeS;if(q>0)dts.Add(q);} dts.Sort(); double med=dts.Count>0?dts[dts.Count/2]:0, hz=med>0?1.0/med:0;
                StringBuilder st=new StringBuilder(); st.Append("["); for(int j=0;j<sf.Count;j++){if(j>0)st.Append(","); StateField f=sf[j]; st.Append("{\"relative_offset\":").Append(f.Rel).Append(",\"unique_values\":[").Append(String.Join(",",f.Unique)).Append("],\"changes\":").Append(f.Changes).Append("}");} st.Append("]");
                string schemaTag = c.P.Name=="2026" ? ",\"record_semantic_schema_version\":"+QQReplaySchema2026.SchemaVersion+",\"contact_state_offset\":"+QQReplaySchema2026.ContactStateOffset+",\"lap_index_offset\":"+QQReplaySchema2026.LapIndexOffset+",\"input_bool_candidate_start\":"+QQReplaySchema2026.InputBoolCandidateStart+",\"input_bool_candidate_end\":"+QQReplaySchema2026.InputBoolCandidateEnd+",\"input_bool_labels_assigned\":false,\"vehicle_forward_axis_local\":\""+QQReplaySchema2026.VehicleForwardAxisLocal+"\"" : "";
                string csvJson=writePhysicalCsv?("\""+csvRel+"\""):"null";
                streamJson.Add("{\"stream_id\":\""+sid+"\",\"primary_by_record_count\":"+(si==primary?"true":"false")+",\"profile\":\""+c.P.Name+"\",\"residue\":"+c.Residue+",\"byte_start\":"+c.StartByte+",\"byte_end\":"+c.EndByte+",\"records\":"+rows.Count+",\"time_start_s\":"+D(rows.Count>0?rows[0].TimeS:0)+",\"time_end_s\":"+D(rows.Count>0?rows[rows.Count-1].TimeS:0)+",\"duration_s\":"+D(dur)+",\"approx_sample_hz\":"+D(hz)+",\"candidate_state_fields\":"+st.ToString()+schemaTag+",\"physical_transport\":\"qpf_v1\",\"fastbin\":\""+fastRel+"\",\"csv\":"+csvJson+"}");
            }
            string map=SafeMapHint(inputs[ri]);
            manifestReplays.Add("{\"replay_id\":\""+replayId+"\",\"map_hint\":\""+JsonEscape(map)+"\",\"detected_profile\":\""+profile+"\",\"source_size_bytes\":"+data.Length+",\"stream_count\":"+streams.Count+",\"streams\":["+String.Join(",",streamJson.ToArray())+"]}");
        }
        string productionSchema="{\"schema_version\":"+QQReplaySchema2026.SchemaVersion+",\"profile\":\"2026\",\"stride\":"+QQReplaySchema2026.Stride+",\"time_ms_offset\":"+QQReplaySchema2026.TimeMsOffset+",\"quaternion_range\":["+QQReplaySchema2026.QuaternionOffset+","+(QQReplaySchema2026.QuaternionOffset+15)+"],\"position_range\":["+QQReplaySchema2026.PositionOffset+","+(QQReplaySchema2026.PositionOffset+11)+"],\"contact_state\":{\"offset\":"+QQReplaySchema2026.ContactStateOffset+",\"type\":\"int32\",\"enum_source\":\"historical_tencentcar_enmcontactstatus\",\"confirmed_values\":{\"0\":\"in_air\",\"1\":\"none_contact\",\"2\":\"one_contact\",\"3\":\"two_contact\",\"4\":\"three_contact\",\"5\":\"full_contact\"}},\"input_bool_block_candidate\":{\"start\":"+QQReplaySchema2026.InputBoolCandidateStart+",\"end\":"+QQReplaySchema2026.InputBoolCandidateEnd+",\"binary\":true,\"labels_assigned\":false},\"lap_index\":{\"offset\":"+QQReplaySchema2026.LapIndexOffset+",\"type\":\"int32\",\"observed_base\":1},\"linear_velocity_range\":["+QQReplaySchema2026.LinearVelocityOffset+","+(QQReplaySchema2026.LinearVelocityOffset+11)+"],\"vehicle_forward_axis_local\":\""+QQReplaySchema2026.VehicleForwardAxisLocal+"\"}";
        string manifest="{\"tool\":\"QQReplayExtractor Portable\",\"tool_version\":\"0.4.2\",\"production_record_schema_2026\":"+productionSchema+",\"privacy\":{\"header_copied\":false,\"nickname_exported\":false,\"chat_exported\":false,\"account_metadata_exported\":false,\"source_filename_exported\":false},\"units\":{\"time\":\"seconds / milliseconds\",\"position\":\"game coordinate units\",\"velocity\":\"game coordinate units per second\",\"acceleration\":\"game coordinate units per second^2\"},\"replays\":["+String.Join(",",manifestReplays.ToArray())+"]}";
        File.WriteAllText(Path.Combine(outRoot,"manifest.json"),manifest,new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(outRoot,"README.txt"),"QQReplayExtractor Portable telemetry package\r\n\r\n不含原始回放头部、昵称、聊天或账号元数据。\r\n每个 stream 的 qpf_v1 快速缓存保存生产分析所需的 typed telemetry；兼容导出模式仍可同时写 CSV。快速生产路径不再扫描/导出已退役的 state_rel 候选字段。\r\n2026 schema v1 额外输出已跨录像确认的 contact_state、contact_state_name、lap_index、vehicle_forward_heading，以及未命名的 input_bool_candidate_60..65。\r\nstate_rel_±N 与 input_bool_candidate_* 不强行解释成氮气、漂移、双喷等高级技巧。\r\n",new UTF8Encoding(true));
    }

    public static void Extract(string[] inputs, string outRoot)
    {
        ExtractInternal(inputs,outRoot,true);
    }

    public static void ExtractFast(string[] inputs, string outRoot)
    {
        ExtractInternal(inputs,outRoot,false);
    }

    public static void ExtractFastFromDelimited(string inputList, string outRoot)
    {
        if (inputList == null) throw new ArgumentNullException("inputList");
        string[] inputs = inputList.Split(new string[]{"\n"}, StringSplitOptions.RemoveEmptyEntries);
        if (inputs.Length == 0) throw new ArgumentException("No replay inputs were provided.");
        ExtractFast(inputs, outRoot);
    }

    public static void ExtractFromDelimited(string inputList, string outRoot)
    {
        if (inputList == null) throw new ArgumentNullException("inputList");
        string[] inputs = inputList.Split(new string[]{"\n"}, StringSplitOptions.RemoveEmptyEntries);
        if (inputs.Length == 0) throw new ArgumentException("No replay inputs were provided.");
        Extract(inputs, outRoot);
    }
}
