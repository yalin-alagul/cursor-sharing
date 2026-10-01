using System.Text;
using System.Text.Json;
using SideCursor.Windows.Core;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Services;

namespace SideCursor.Windows.Tests;

public sealed class DisplayLayoutTests
{
    // 27" 4K Dell as primary, and a 1920 x 1200 laptop panel to its right.
    private static readonly DisplayDescriptor Dell = Display("DELL", new PixelBounds(0, 0, 3840, 2160), primary: true, 597, 336);
    private static readonly DisplayDescriptor Laptop = Display("LAPTOP", new PixelBounds(3840, 0, 1920, 1200), primary: false, 302, 188);

    // The MacBook (900 pt tall) touches the Dell's left edge along its top
    // 179 mm, which is 0..1151 px on the Dell.
    private static readonly ReturnZone DellLeftZone = new(
        "DELL",
        ScreenEdge.Left,
        0,
        0,
        1151,
        new MacZoneSide("MAC", ScreenEdge.Right, 1440, 0, 900));

    [Fact]
    public void PointerMovesFreelyInsideAndAcrossWindowsDisplays()
    {
        var inside = DesktopPointerPlanner.Plan(new PixelPoint(100, 100), new PixelPoint(20, 5), [Dell, Laptop], [DellLeftZone]);
        Assert.Equal(new PixelPoint(120, 105), inside.MoveTo);
        Assert.Null(inside.Zone);

        var across = DesktopPointerPlanner.Plan(new PixelPoint(3835, 500), new PixelPoint(20, 0), [Dell, Laptop], [DellLeftZone]);
        Assert.Equal(new PixelPoint(3855, 500), across.MoveTo);
        Assert.Null(across.Zone);
    }

    [Fact]
    public void LeavingThroughAReturnZoneReturnsAtThePhysicallyMatchingMacPoint()
    {
        var plan = DesktopPointerPlanner.Plan(new PixelPoint(3, 575), new PixelPoint(-10, 0), [Dell, Laptop], [DellLeftZone]);

        Assert.Equal(DellLeftZone, plan.Zone);
        Assert.Equal(new PixelPoint(0, 575), plan.MoveTo);
        var mac = Assert.IsType<MacReturnPoint>(plan.MacPoint);
        Assert.Equal("MAC", mac.Display);
        Assert.Equal(ScreenEdge.Right, mac.Edge);
        Assert.Equal(1440, mac.X);
        Assert.Equal(575.0 / 1151 * 900, mac.Y, 3);
    }

    [Fact]
    public void TheRestOfAnEdgeIsAWallThatDoesNotReturn()
    {
        // Below the shared 179 mm, the Dell's left edge touches nothing.
        var plan = DesktopPointerPlanner.Plan(new PixelPoint(3, 1800), new PixelPoint(-10, 4), [Dell, Laptop], [DellLeftZone]);

        Assert.Null(plan.Zone);
        Assert.Equal(new PixelPoint(0, 1804), plan.MoveTo);
    }

    [Fact]
    public void OuterEdgesWithoutZonesStopThePointer()
    {
        var top = DesktopPointerPlanner.Plan(new PixelPoint(500, 2), new PixelPoint(0, -10), [Dell, Laptop], [DellLeftZone]);
        Assert.Null(top.Zone);
        Assert.Equal(new PixelPoint(500, 0), top.MoveTo);

        // Already at the wall: nothing to move.
        var parked = DesktopPointerPlanner.Plan(new PixelPoint(500, 0), new PixelPoint(0, -10), [Dell, Laptop], [DellLeftZone]);
        Assert.Null(parked.MoveTo);
    }

    [Fact]
    public void PhysicalScaleMatchesMillimetresAcrossDifferentDensities()
    {
        // MacBook: 1440 pt over 287 mm. Dell: 3840 px over 597 mm.
        var scale = RelativeMotionMapper.PhysicalScale(1440 / 287.0, 900 / 179.0, Dell.Bounds, new DisplaySizeMm(597, 336));

        Assert.NotNull(scale);
        Assert.Equal(3840 / 597.0 / (1440 / 287.0), scale.Value.X, 6);
        // 287 Mac points (57.2 mm) must move the Dell pointer 57.2 mm, which
        // is 367.9 px (whole pixels are injected; the fraction carries over).
        var mapper = new RelativeMotionMapper();
        mapper.Configure(1440, 900, Dell.Bounds, 1.0);
        mapper.SetScale(scale.Value.X, scale.Value.Y);
        var moved = mapper.Translate(287, 0);
        Assert.InRange(moved.X, 367, 368);

        Assert.Null(RelativeMotionMapper.PhysicalScale(0, 0, Dell.Bounds, new DisplaySizeMm(597, 336)));
    }

    [Fact]
    public void EdidParsingReadsDetailedSizeAndMonitorName()
    {
        var info = Edid.Parse(MakeEdid(597, 336, 60, 34, "DELL S2725QS"));

        Assert.NotNull(info);
        Assert.Equal(597, info.Value.WidthMm);
        Assert.Equal(336, info.Value.HeightMm);
        Assert.Equal("DELL S2725QS", info.Value.Name);
    }

    [Fact]
    public void EdidParsingFallsBackToCentimetresAndRejectsGarbage()
    {
        var info = Edid.Parse(MakeEdid(0, 0, 60, 34, null));
        Assert.Equal(600, info!.Value.WidthMm);
        Assert.Equal(340, info.Value.HeightMm);
        Assert.Null(info.Value.Name);

        Assert.Null(Edid.Parse(new byte[128]));
    }

    [Fact]
    public void MonitorInterfaceMapsToItsEdidRegistryKey()
    {
        Assert.Equal(
            @"SYSTEM\CurrentControlSet\Enum\DISPLAY\DELA277\4&2638bbf3&0&UID4145\Device Parameters",
            Edid.RegistryKeyForInterface(@"\\?\DISPLAY#DELA277#4&2638bbf3&0&UID4145#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}"));
        Assert.Null(Edid.RegistryKeyForInterface("MONITOR\\DELA277\\{4d36e96e}\\0002"));
    }

    [Fact]
    public void RotatedDisplaysSwapTheLandscapeEdidSize()
    {
        var portrait = DisplayCatalog.OrientedSize(new EdidInfo(597, 336, null), new PixelBounds(0, 0, 2160, 3840));
        Assert.Equal((336.0, 597.0), portrait);
    }

    [Fact]
    public void LayoutMessageParsesSizesAndZones()
    {
        using var document = JsonDocument.Parse("""
            {"type":"layout",
             "displays":[{"id":"dell","widthMm":597,"heightMm":336}],
             "zones":[{"display":"DELL","edge":"left","line":0,"start":0,"end":1151,
                       "mac":{"display":"MAC","edge":"right","line":1440,"start":0,"end":900}}]}
            """);

        var layout = WindowsSession.ParseLayout(document.RootElement);

        Assert.Equal(new DisplaySizeMm(597, 336), layout.Sizes["DELL"]);
        Assert.Equal(DellLeftZone, Assert.Single(layout.Zones));
    }

    [Fact]
    public void LayoutMessageRejectsUnknownEdges()
    {
        using var document = JsonDocument.Parse("""
            {"type":"layout","displays":[],
             "zones":[{"display":"D","edge":"diagonal","line":0,"start":0,"end":1,
                       "mac":{"display":"M","edge":"right","line":0,"start":0,"end":1}}]}
            """);

        Assert.Throws<SideCursor.Windows.Protocol.ProtocolViolationException>(() => WindowsSession.ParseLayout(document.RootElement));
    }

    private static DisplayDescriptor Display(string id, PixelBounds bounds, bool primary, double widthMm, double heightMm) =>
        new(id, $@"\\.\{id}", id, bounds, 96, 96, primary, widthMm, heightMm);

    private static byte[] MakeEdid(int widthMm, int heightMm, byte widthCm, byte heightCm, string? name)
    {
        var edid = new byte[128];
        new byte[] { 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 }.CopyTo(edid, 0);
        edid[21] = widthCm;
        edid[22] = heightCm;
        if (widthMm > 0)
        {
            edid[54] = 0x01; // non-zero pixel clock marks a detailed timing
            edid[66] = (byte)(widthMm & 0xFF);
            edid[67] = (byte)(heightMm & 0xFF);
            edid[68] = (byte)(((widthMm >> 8) << 4) | (heightMm >> 8));
        }

        if (name is not null)
        {
            edid[75] = 0xFC; // second descriptor: monitor name
            var text = Encoding.ASCII.GetBytes((name + "\n").PadRight(13));
            text.AsSpan(0, 13).CopyTo(edid.AsSpan(77));
        }

        return edid;
    }
}
