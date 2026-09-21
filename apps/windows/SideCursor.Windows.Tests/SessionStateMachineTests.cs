using SideCursor.Windows.Core;

namespace SideCursor.Windows.Tests;

public sealed class SessionStateMachineTests
{
    [Fact]
    public void ValidLifecycleReachesReadyAfterReturn()
    {
        var state = new SessionStateMachine();

        Assert.True(state.BeginConnecting());
        Assert.True(state.MarkReady());
        Assert.True(state.BeginEntering());
        Assert.True(state.MarkRemote());
        Assert.True(state.BeginReturning());
        Assert.True(state.CompleteReturn());

        Assert.Equal(SessionState.Ready, state.Snapshot.State);
    }

    [Fact]
    public void InputCannotEnterBeforeAuthenticatedReadyState()
    {
        var state = new SessionStateMachine();

        Assert.False(state.BeginEntering());
        Assert.Equal(SessionState.Disconnected, state.Snapshot.State);
    }

    [Fact]
    public void RecoveryIsMandatoryBeforeDisconnect()
    {
        var state = new SessionStateMachine();
        var observed = new List<SessionState>();
        state.Changed += (_, snapshot) => observed.Add(snapshot.State);

        Assert.True(state.BeginConnecting());
        state.ForceDisconnected("transport failure");

        Assert.Equal([SessionState.Connecting, SessionState.Recovering, SessionState.Disconnected], observed);
        Assert.Equal(SessionState.Disconnected, state.Snapshot.State);
    }
}
