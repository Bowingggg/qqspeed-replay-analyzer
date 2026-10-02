using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Xml;

public sealed class QQNativeDrivingSurfaceIndex
{
    private struct Tri
    {
        public double Ax, Ay, Bx, By, Cx, Cy;
        public double MinX, MaxX, MinY, MaxY;
    }

    private readonly List<Tri> _triangles = new List<Tri>();
    private readonly Dictionary<int, List<int>> _buckets = new Dictionary<int, List<int>>();
    private readonly int _grid;
    private readonly double _canvasWidth;
    private readonly double _canvasHeight;
    private readonly double _cellWidth;
    private readonly double _cellHeight;
    private readonly double _worldMinX;
    private readonly double _worldMinY;
    private readonly double _scale;
    private readonly double _offsetX;
    private readonly double _offsetY;
    private readonly bool _yInverted;

    public int TriangleCount { get { return _triangles.Count; } }

    private QQNativeDrivingSurfaceIndex(int grid, double canvasWidth, double canvasHeight,
        double worldMinX, double worldMinY, double scale, double offsetX, double offsetY, bool yInverted)
    {
        _grid = Math.Max(8, Math.Min(128, grid));
        _canvasWidth = Math.Max(1.0, canvasWidth);
        _canvasHeight = Math.Max(1.0, canvasHeight);
        _cellWidth = _canvasWidth / _grid;
        _cellHeight = _canvasHeight / _grid;
        _worldMinX = worldMinX;
        _worldMinY = worldMinY;
        _scale = scale;
        _offsetX = offsetX;
        _offsetY = offsetY;
        _yInverted = yInverted;
    }

    public static QQNativeDrivingSurfaceIndex Load(string svgPath, int grid,
        double canvasWidth, double canvasHeight, double worldMinX, double worldMinY,
        double scale, double offsetX, double offsetY, bool yInverted)
    {
        if (String.IsNullOrWhiteSpace(svgPath) || !File.Exists(svgPath))
            throw new FileNotFoundException("official map SVG not found", svgPath);
        if (scale <= 0.0 || Double.IsNaN(scale) || Double.IsInfinity(scale))
            throw new InvalidDataException("invalid native-map render scale");

        QQNativeDrivingSurfaceIndex idx = new QQNativeDrivingSurfaceIndex(
            grid, canvasWidth, canvasHeight, worldMinX, worldMinY, scale, offsetX, offsetY, yInverted);

        XmlDocument doc = new XmlDocument();
        doc.XmlResolver = null;
        doc.Load(svgPath);
        XmlNodeList nodes = doc.GetElementsByTagName("polygon");
        for (int i = 0; i < nodes.Count; i++)
        {
            XmlElement el = nodes[i] as XmlElement;
            if (el == null) continue;
            string raw = el.GetAttribute("points");
            if (String.IsNullOrWhiteSpace(raw)) continue;
            string[] pairs = raw.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            if (pairs.Length != 3) continue;
            double[] xy = new double[6];
            bool ok = true;
            for (int p = 0; p < 3; p++)
            {
                string[] parts = pairs[p].Split(',');
                if (parts.Length != 2 ||
                    !Double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out xy[p * 2]) ||
                    !Double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out xy[p * 2 + 1]))
                { ok = false; break; }
            }
            if (!ok) continue;
            idx.AddTriangle(xy[0], xy[1], xy[2], xy[3], xy[4], xy[5]);
        }
        if (idx._triangles.Count == 0)
            throw new InvalidDataException("official map SVG contains no triangle polygons");
        return idx;
    }

    private int ClampCellX(double x)
    {
        int c = (int)Math.Floor(x / _cellWidth);
        if (c < 0) return 0;
        if (c >= _grid) return _grid - 1;
        return c;
    }
    private int ClampCellY(double y)
    {
        int c = (int)Math.Floor(y / _cellHeight);
        if (c < 0) return 0;
        if (c >= _grid) return _grid - 1;
        return c;
    }
    private int Key(int cx, int cy) { return cy * _grid + cx; }

    private void AddTriangle(double ax, double ay, double bx, double by, double cx, double cy)
    {
        Tri t = new Tri();
        t.Ax = ax; t.Ay = ay; t.Bx = bx; t.By = by; t.Cx = cx; t.Cy = cy;
        t.MinX = Math.Min(ax, Math.Min(bx, cx)); t.MaxX = Math.Max(ax, Math.Max(bx, cx));
        t.MinY = Math.Min(ay, Math.Min(by, cy)); t.MaxY = Math.Max(ay, Math.Max(by, cy));
        int ti = _triangles.Count;
        _triangles.Add(t);
        int x0 = ClampCellX(t.MinX), x1 = ClampCellX(t.MaxX);
        int y0 = ClampCellY(t.MinY), y1 = ClampCellY(t.MaxY);
        for (int yy = y0; yy <= y1; yy++)
        {
            for (int xx = x0; xx <= x1; xx++)
            {
                int key = Key(xx, yy);
                List<int> list;
                if (!_buckets.TryGetValue(key, out list))
                {
                    list = new List<int>();
                    _buckets[key] = list;
                }
                list.Add(ti);
            }
        }
    }

    private void WorldToCanvas(double x, double y, out double px, out double py)
    {
        px = _offsetX + (x - _worldMinX) * _scale;
        double rawY = _offsetY + (y - _worldMinY) * _scale;
        py = _yInverted ? (_canvasHeight - rawY) : rawY;
    }

    private static double Cross(double ax, double ay, double bx, double by, double px, double py)
    {
        return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    }

    private static bool Contains(Tri t, double x, double y)
    {
        const double eps = 0.35;
        if (x < t.MinX - eps || x > t.MaxX + eps || y < t.MinY - eps || y > t.MaxY + eps) return false;
        double c1 = Cross(t.Ax, t.Ay, t.Bx, t.By, x, y);
        double c2 = Cross(t.Bx, t.By, t.Cx, t.Cy, x, y);
        double c3 = Cross(t.Cx, t.Cy, t.Ax, t.Ay, x, y);
        bool neg = (c1 < -eps) || (c2 < -eps) || (c3 < -eps);
        bool pos = (c1 > eps) || (c2 > eps) || (c3 > eps);
        return !(neg && pos);
    }

    public bool ContainsWorld(double x, double y)
    {
        double px, py;
        WorldToCanvas(x, y, out px, out py);
        if (px < -1.0 || py < -1.0 || px > _canvasWidth + 1.0 || py > _canvasHeight + 1.0) return false;
        int cx = ClampCellX(px), cy = ClampCellY(py);
        List<int> list;
        if (!_buckets.TryGetValue(Key(cx, cy), out list)) return false;
        for (int i = 0; i < list.Count; i++)
        {
            if (Contains(_triangles[list[i]], px, py)) return true;
        }
        return false;
    }
}

// Telemetry row materialisation for the derived driving analyses.
//
// The production logical telemetry CSV has 6.4k-9k rows. Building one PowerShell PSCustomObject per
// row costs ~0.3 ms/row (~2.3-2.8 s per stream), which dominated the warm analysis path once
// Driving Analysis v2 started consuming the rows as well. This typed row plus a hand-written reader
// produces the identical field set (i/t/x/y/z/speed/distance/lap_index/pose_valid/break_before) and
// the identical fallbacks (speed and distance fall back to 0.0, every other numeric field to NaN).
public sealed class QQNativeDrivingRow
{
    public int i;
    public double t;
    public double x;
    public double y;
    public double z;
    public double speed;
    public double distance;
    public int lap_index;
    public bool has_lap_index;
    public bool pose_valid;
    public bool break_before;
}

public static class QQNativeDrivingCsv
{
    private static readonly string[] Required = new string[]
    {
        "time_s","x","y","z","speed","distance","pose_valid","pose_break_before"
    };

    private static int Column(Dictionary<string,int> map,string name,string path)
    {
        int idx;
        if(!map.TryGetValue(name,out idx))
            throw new InvalidDataException("telemetry csv is missing the column: "+name+" ("+path+")");
        return idx;
    }

    // A CSV field may be quoted (Export-Csv quotes any field that needs it, and in practice all of
    // them here). Import-Csv removed the quotes; this reader must behave the same for header names
    // and for every value.
    private static string AsRaw(string s)
    {
        if(s==null)return "";
        s=s.Trim();
        if(s.Length>=2&&s[0]=='"'&&s[s.Length-1]=='"')s=s.Substring(1,s.Length-2).Trim();
        s=s.TrimStart('\uFEFF').Trim();
        return s;
    }

    private static bool AsBool(string s)
    {
        string v=AsRaw(s);
        if(v.Length==0)return false;
        return String.Equals(v,"true",StringComparison.OrdinalIgnoreCase)||v=="1";
    }

    private static double AsDouble(string s,double fallback)
    {
        string v=AsRaw(s);
        if(v.Length==0)return fallback;
        double d;
        if(Double.TryParse(v,NumberStyles.Float,CultureInfo.InvariantCulture,out d))return d;
        return fallback;
    }

    public static QQNativeDrivingRow[] Load(string path)
    {
        string[] lines=File.ReadAllLines(path);
        var rows=new List<QQNativeDrivingRow>();
        if(lines.Length<2)return rows.ToArray();

        string[] header=lines[0].Split(',');
        // A UTF-8 BOM survives into the first field when a CSV is written by Export-Csv. Import-Csv
        // used to strip it; keep that behaviour so both writers load identically.
        
        var col=new Dictionary<string,int>(StringComparer.Ordinal);
        for(int k=0;k<header.Length;k++)col[AsRaw(header[k])]=k;

        int ciT=Column(col,"time_s",path), ciX=Column(col,"x",path), ciY=Column(col,"y",path);
        int ciZ=Column(col,"z",path), ciSpeed=Column(col,"speed",path), ciDist=Column(col,"distance",path);
        int ciOk=Column(col,"pose_valid",path), ciBreak=Column(col,"pose_break_before",path);
        int ciLap=-1;
        col.TryGetValue("lap_index",out ciLap);

        int max=Math.Max(Math.Max(ciT,ciX),Math.Max(Math.Max(ciY,ciZ),Math.Max(Math.Max(ciSpeed,ciDist),Math.Max(Math.Max(ciOk,ciBreak),ciLap))));
        int index=0;
        for(int li=1;li<lines.Length;li++)
        {
            string line=lines[li];
            if(String.IsNullOrWhiteSpace(line))continue;
            string[] c=line.Split(',');
            if(c.Length<=max)continue;
            var r=new QQNativeDrivingRow();
            r.i=index;
            r.t=AsDouble(c[ciT],Double.NaN);
            r.x=AsDouble(c[ciX],Double.NaN);
            r.y=AsDouble(c[ciY],Double.NaN);
            r.z=AsDouble(c[ciZ],Double.NaN);
            r.speed=AsDouble(c[ciSpeed],0.0);
            r.distance=AsDouble(c[ciDist],0.0);
            r.pose_valid=AsBool(c[ciOk]);
            r.break_before=AsBool(c[ciBreak]);
            if(ciLap>=0&&!String.IsNullOrWhiteSpace(c[ciLap]))
            {
                int lap;
                if(Int32.TryParse(AsRaw(c[ciLap]),NumberStyles.Integer,CultureInfo.InvariantCulture,out lap))
                {
                    r.lap_index=lap;
                    r.has_lap_index=true;
                }
            }
            rows.Add(r);
            index++;
        }
        return rows.ToArray();
    }
}