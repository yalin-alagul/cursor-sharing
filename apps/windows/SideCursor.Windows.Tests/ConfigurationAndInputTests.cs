using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using SideCursor.Windows.Core;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Protocol;

namespace SideCursor.Windows.Tests;

public sealed class ConfigurationAndInputTests
{
    [Fact]
    public void DefaultCalibrationIsNaturalOnePointZero()
    {
        Assert.Equal(1.0, new SideCursorConfig().PointerCalibration);
    }

    [Fact]
    public void TargetResolutionPrefersTheSavedDisplay()
    {
        var displays = new[] { Display("DELL-A", primary: true), Display("DELL-B", primary: false) };

        var target = DisplayCatalog.ResolveTarget(new SideCursorConfig { TargetDisplayId = "dell-b" }, displays);

        Assert.Equal("DELL-B", target.StableId);
    }

    [Fact]
    public void TargetResolutionFallsBackToPrimaryWhenSavedDisplayIsDisconnected()
    {
        // A different monitor on the dock used to reject every remote entry
        // until the target was re-selected by hand.
        var displays = new[] { Display("LAPTOP", primary: false), Display("DELL-B", primary: true) };
        var configuration = new SideCursorConfig { TargetDisplayId = "DELL-A" };

        var target = DisplayCatalog.ResolveTarget(configuration, displays);

        Assert.Equal("DELL-B", target.StableId);
        Assert.False(DisplayCatalog.IsConfiguredTarget(configuration, target));
    }

    [Fact]
    public void TargetResolutionFallsBackToFirstDisplayWithoutAPrimary()
    {
        var displays = new[] { Display("ONE", primary: false), Display("TWO", primary: false) };

        var target = DisplayCatalog.ResolveTarget(new SideCursorConfig { TargetDisplayId = "GONE" }, displays);

        Assert.Equal("ONE", target.StableId);
    }

    [Fact]
    public void TargetResolutionUsesTheOnlyDisplayWhenNoneIsSaved()
    {
        var target = DisplayCatalog.ResolveTarget(new SideCursorConfig(), new[] { Display("ONLY", primary: true) });

        Assert.Equal("ONLY", target.StableId);
    }

    [Fact]
    public void TargetResolutionThrowsWithoutAnyDisplay()
    {
        Assert.Throws<InvalidOperationException>(
            () => DisplayCatalog.ResolveTarget(new SideCursorConfig(), Array.Empty<DisplayDescriptor>()));
    }

    [Fact]
    public void ZoomWrapsTheWheelInCtrlWithinOneBatch()
    {
        var inputs = WindowsInputInjector.BuildZoomInputs(2, ctrlHeld: false);

        Assert.Equal(3, inputs.Length);
        Assert.Equal(NativeMethods.InputKeyboard, inputs[0].Type);
        Assert.Equal(0x11, inputs[0].Data.Keyboard.VirtualKey);
        Assert.Equal(0u, inputs[0].Data.Keyboard.Flags & NativeMethods.KeyeventfKeyUp);
        Assert.Equal(NativeMethods.MouseeventfWheel, inputs[1].Data.Mouse.Flags);
        Assert.Equal(240, unchecked((int)inputs[1].Data.Mouse.MouseData));
        Assert.Equal(0x11, inputs[2].Data.Keyboard.VirtualKey);
        Assert.NotEqual(0u, inputs[2].Data.Keyboard.Flags & NativeMethods.KeyeventfKeyUp);
    }

    [Fact]
    public void ZoomOutUsesNegativeWheelAndSkipsCtrlTheUserAlreadyHolds()
    {
        var inputs = WindowsInputInjector.BuildZoomInputs(-1, ctrlHeld: true);

        var wheel = Assert.Single(inputs);
        Assert.Equal(NativeMethods.InputMouse, wheel.Type);
        Assert.Equal(-120, unchecked((int)wheel.Data.Mouse.MouseData));
    }

    [Fact]
    public void LargeClipboardSplitsWithoutBreakingSurrogatePairsAndReassembles()
    {
        var text = string.Concat(Enumerable.Repeat("Yalın 🙂 ", 20_000));
        var parts = ClipboardParts.Split(text, V2Protocol.ClipboardPartBytes);

        Assert.True(parts.Count > 1);
        Assert.All(parts, part =>
        {
            Assert.True(System.Text.Encoding.UTF8.GetByteCount(part) <= V2Protocol.ClipboardPartBytes);
            Assert.False(char.IsHighSurrogate(part[^1]));
        });

        var assembler = new ClipboardAssembler();
        var id = Guid.NewGuid().ToString("D");
        (string Format, string Payload)? result = null;
        for (var index = 0; index < parts.Count; index++)
        {
            result = assembler.Add(id, index, parts.Count, "text", parts[index], V2Protocol.MaximumClipboardBytes, V2Protocol.MaximumClipboardParts);
        }

        Assert.Equal(("text", text), result);
    }

    [Fact]
    public void ImageTravelsAsBase64PartsAndDecodesBackToTheSamePixels()
    {
        var pixels = new byte[64 * 48 * 4];
        new Random(7).NextBytes(pixels);
        var source = System.Windows.Media.Imaging.BitmapSource.Create(
            64, 48, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null, pixels, 64 * 4);
        var png = ClipboardImages.ToPng(source);

        var parts = ClipboardParts.Split(Convert.ToBase64String(png), V2Protocol.ClipboardPartBytes);
        var assembler = new ClipboardAssembler();
        (string Format, string Payload)? result = null;
        for (var index = 0; index < parts.Count; index++)
        {
            result = assembler.Add("img", index, parts.Count, "png", parts[index], png.Length, V2Protocol.MaximumClipboardParts);
        }

        Assert.Equal("png", result!.Value.Format);
        var decoded = ClipboardImages.FromPng(Convert.FromBase64String(result.Value.Payload));
        Assert.Equal(64, decoded.PixelWidth);
        var roundTrip = new byte[pixels.Length];
        new System.Windows.Media.Imaging.FormatConvertedBitmap(decoded, System.Windows.Media.PixelFormats.Bgra32, null, 0)
            .CopyPixels(roundTrip, 64 * 4, 0);
        Assert.Equal(pixels, roundTrip);

        // Clipboard padding after IEND must not change what is compared or sent.
        Assert.Equal(png, ClipboardImages.TrimToPngEnd([.. png, 0, 0, 0, 0]));
    }

    [Fact]
    public void ClipboardTransferMustKeepOneFormat()
    {
        var assembler = new ClipboardAssembler();
        Assert.Null(assembler.Add("x", 0, 2, "png", "iVBO", 100, 10));
        Assert.Null(assembler.Add("x", 1, 2, "text", "Rw==", 100, 10));
    }

    [Fact]
    public void ClipboardAssemblerDropsSupersededAndOversizedTransfers()
    {
        var assembler = new ClipboardAssembler();
        Assert.Null(assembler.Add("a", 0, 2, "text", "old ", 100, 10));
        Assert.Null(assembler.Add("b", 0, 2, "text", "new ", 100, 10));
        Assert.Null(assembler.Add("a", 1, 2, "text", "tail", 100, 10));
        Assert.Equal(("text", "new text"), assembler.Add("b", 1, 2, "text", "text", 100, 10));

        Assert.Null(assembler.Add("c", 0, 2, "text", "12345", 8, 10));
        Assert.Null(assembler.Add("c", 1, 2, "text", "67890", 8, 10));
    }

    [Fact]
    public void VersionOneClipboardCeilingMigratesToTenMegabytes()
    {
        var migrated = new SideCursorConfig { SchemaVersion = 1, ClipboardMaximumBytes = 1024 * 1024 };
        migrated.Normalize();
        Assert.Equal(10 * 1024 * 1024, migrated.ClipboardMaximumBytes);

        var chosen = new SideCursorConfig { SchemaVersion = 1, ClipboardMaximumBytes = 64 * 1024 };
        chosen.Normalize();
        Assert.Equal(64 * 1024, chosen.ClipboardMaximumBytes);
    }

    [Fact]
    public void AbsolutePointerIsOnByDefaultForUnacceleratedMotion()
    {
        Assert.True(new SideCursorConfig().AbsolutePointer);
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
    public void PairingParserRejectsAPassphraseInsteadOfHashingIt()
    {
        // macOS requires the exact 32-byte base64url secret, so hashing an
        // arbitrary passphrase here used to "succeed" without ever pairing.
        Assert.Throws<ArgumentException>(() => PairingSecretParser.Parse("correct horse battery staple"));
    }

    [Theory]
    [InlineData("f1", "F1")]
    [InlineData("F24", "F24")]
    public void FunctionKeysAreCaseInsensitive(string source, string expected)
    {
        Assert.True(HotkeyChord.TryParse(source, out var hotkey));
        Assert.Equal(expected, hotkey.ToString());
    }

    [Fact]
    public void CorruptSettingsFileFallsBackToDefaultsAndKeepsACopy()
    {
        var root = Path.Combine(Path.GetTempPath(), "sidecursor-tests-" + Guid.NewGuid().ToString("N"));
        try
        {
            var paths = new AppDataPaths(root);
            Directory.CreateDirectory(root);
            File.WriteAllText(paths.ConfigurationPath, "{ this is not valid json");
            var store = new ConfigurationStore(paths);

            var configuration = store.Load();

            Assert.Equal(24800, configuration.PeerPort);
            Assert.True(File.Exists(paths.ConfigurationPath + ".corrupt"));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
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

    private static DisplayDescriptor Display(string stableId, bool primary) =>
        new(stableId, $@"\\.\{stableId}", stableId, new PixelBounds(0, 0, 1920, 1080), 96, 96, primary);
}
