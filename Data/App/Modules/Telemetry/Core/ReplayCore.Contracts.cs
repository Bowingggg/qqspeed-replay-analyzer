public static class QQReplaySchema2026
{
    public const int SchemaVersion = 1;
    public const int Stride = 230;
    public const int TimeMsOffset = 0;
    public const int QuaternionOffset = 8;
    public const int PositionOffset = 24;
    public const int ContactStateOffset = 52;
    public const int InputBoolCandidateStart = 60;
    public const int InputBoolCandidateEnd = 65;
    public const int LapIndexOffset = 76;
    public const int LinearVelocityOffset = 173;
    public const string VehicleForwardAxisLocal = "-Y";

    public static string ContactStateName(int value)
    {
        switch (value)
        {
            case 0: return "in_air";
            case 1: return "none_contact";
            case 2: return "one_contact";
            case 3: return "two_contact";
            case 4: return "three_contact";
            case 5: return "full_contact";
            default: return "unknown_" + value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}

public static class QQReplayBinary
{
    public static uint U32(byte[] data, int offset) { return System.BitConverter.ToUInt32(data, offset); }
    public static int I32(byte[] data, int offset) { return System.BitConverter.ToInt32(data, offset); }
    public static float F32(byte[] data, int offset) { return System.BitConverter.ToSingle(data, offset); }
}

public static class QQReplayKinematics
{
    public static bool Finite(double value)
    {
        return !(System.Double.IsNaN(value) || System.Double.IsInfinity(value));
    }

    public static double Hypot(double x, double y)
    {
        return System.Math.Sqrt(x * x + y * y);
    }

    public static double WrapPi(double value)
    {
        double turn = 2.0 * System.Math.PI;
        value = (value + System.Math.PI) % turn;
        if (value < 0) value += turn;
        return value - System.Math.PI;
    }

    public static double QuaternionYaw(double qx, double qy, double qz, double qw)
    {
        return System.Math.Atan2(2.0 * (qw * qz + qx * qy), 1.0 - 2.0 * (qy * qy + qz * qz));
    }

    public static double VehicleForwardHeadingMinusY(double qx, double qy, double qz, double qw)
    {
        // Rotate local -Y by quaternion, then project to world XY.
        double fx = -2.0 * (qx * qy - qw * qz);
        double fy = -(1.0 - 2.0 * (qx * qx + qz * qz));
        return System.Math.Atan2(fy, fx);
    }
}
