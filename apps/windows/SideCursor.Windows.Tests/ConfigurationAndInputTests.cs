using System.Security.Cryptography;
using SideCursor.Windows.Core;
using SideCursor.Windows.Infrastructure;

namespace SideCursor.Windows.Tests;

public sealed class ConfigurationAndInputTests
{
    [Fact]
    public void DefaultCalibrationIsNaturalOnePointZero()
    {
        Assert.Equal(1.0, new SideCursorConfig().PointerCalibration);
    }

    [Fact]
    public void PairingParserPreservesBase64UrlThirtyTwoByteSecret()
    {
        var expected = RandomNumberGenerator.GetBytes(32);
        var encoded = Convert.ToBase64String(expected).TrimEnd('=').Replace('+', '-').Replace('/', '_');

        var parsed = PairingSecretParser.Parse(encoded);

        Assert.Equal(expected, parsed);
        CryptographicOperations.ZeroMemory(expected);
        CryptographicOperations.ZeroMemory(parsed);
    }

    [Fact]
    public void RelativeMotionMapsFullSourceDisplayAtOnePointZeroCalibration()
    {
        var mapper = new RelativeMotionMapper();
        mapper.Configure(2048, 1152, new PixelBounds(0, 0, 3840, 2160), 1.0);

        var mapped = mapper.Translate(2048, 1152);

        Assert.Equal(new PixelPoint(3840, 2160), mapped);
    }

    [Fact]
    public void RelativeMotionKeepsFractionalDeltasInsteadOfDroppingThem()
    {
        var mapper = new RelativeMotionMapper();
        mapper.Configure(1000, 1000, new PixelBounds(0, 0, 500, 500), 1.0);

        Assert.Equal(new PixelPoint(0, 0), mapper.Translate(1, 1));
        Assert.Equal(new PixelPoint(1, 1), mapper.Translate(1, 1));
    }

    [Theory]
    [InlineData("WIN+CTRL+LEFT", "WIN+CTRL+LEFT")]
    [InlineData("windows+control+right", "WIN+CTRL+RIGHT")]
    [InlineData("win+tab", "WIN+TAB")]
    public void HotkeysAreNormalized(string source, string expected)
    {
        Assert.True(HotkeyChord.TryParse(source, out var hotkey));
        Assert.Equal(expected, hotkey.ToString());
    }

    [Fact]
    public void TargetEntryUsesItsOwnLeftEdgeAndNormalizedY()
    {
        var bounds = new PixelBounds(-1920, 100, 3840, 2160);

        var point = bounds.EntryPoint(0.5, 2);

        Assert.Equal(-1918, point.X);
        Assert.InRange(point.Y, 1179, 1181);
    }

    [Fact]
    public void ReturnEdgeClampsLargeNegativeMotionInsideSelectedNegativeCoordinateDisplay()
    {
        var target = new PixelBounds(-3840, 0, 3840, 2160);

        var plan = ReturnEdgePlanner.Plan(
            current: new PixelPoint(-3810, 900),
            relative: new PixelPoint(-500, 40),
            target,
            requestedInsetPixels: 1);

        Assert.True(plan.RequestReturn);
        Assert.Equal(new PixelPoint(-3839, 940), plan.ClampCursorTo!.Value);
    }

    [Fact]
    public void ReturnEdgeLeavesMovementAloneUntilTheConfiguredLeftBoundary()
    {
        var target = new PixelBounds(100, -400, 1920, 1080);

        var plan = ReturnEdgePlanner.Plan(
            current: new PixelPoint(700, 200),
            relative: new PixelPoint(-20, 0),
            target,
            requestedInsetPixels: 2);

        Assert.False(plan.RequestReturn);
        Assert.Null(plan.ClampCursorTo);
    }
}
