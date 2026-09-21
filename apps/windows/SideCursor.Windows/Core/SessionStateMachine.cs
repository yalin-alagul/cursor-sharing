namespace SideCursor.Windows.Core;

public sealed class SessionStateMachine
{
    private readonly object _gate = new();
    private SessionSnapshot _snapshot = new(SessionState.Disconnected, "Not connected", DateTimeOffset.UtcNow);

    public event EventHandler<SessionSnapshot>? Changed;

    public SessionSnapshot Snapshot
    {
        get
        {
            lock (_gate)
            {
                return _snapshot;
            }
        }
    }

    public bool BeginConnecting(string detail = "Connecting to paired peer") =>
        TryTransition(SessionState.Connecting, detail, SessionState.Disconnected);

    public bool MarkReady(string detail = "Paired peer is ready") =>
        TryTransition(SessionState.Ready, detail, SessionState.Connecting, SessionState.Recovering);

    public bool BeginEntering(string detail = "Preparing Windows input") =>
        TryTransition(SessionState.Entering, detail, SessionState.Ready);

    public bool MarkRemote(string detail = "Controlling Windows") =>
        TryTransition(SessionState.Remote, detail, SessionState.Entering);

    public bool BeginReturning(string detail = "Returning control to Mac") =>
        TryTransition(SessionState.Returning, detail, SessionState.Remote);

    public bool CompleteReturn(string detail = "Paired peer is ready") =>
        TryTransition(SessionState.Ready, detail, SessionState.Returning);

    public void BeginRecovery(string detail)
    {
        SessionSnapshot? changed;
        lock (_gate)
        {
            changed = _snapshot.State == SessionState.Recovering
                ? null
                : _snapshot = new SessionSnapshot(SessionState.Recovering, detail, DateTimeOffset.UtcNow);
        }

        if (changed is not null)
        {
            Changed?.Invoke(this, changed);
        }
    }

    public bool FinishRecovery(bool peerStillConnected, string detail)
    {
        return TryTransition(
            peerStillConnected ? SessionState.Ready : SessionState.Disconnected,
            detail,
            SessionState.Recovering);
    }

    public void ForceDisconnected(string detail)
    {
        SessionSnapshot? recovering;
        SessionSnapshot? disconnected;
        lock (_gate)
        {
            if (_snapshot.State == SessionState.Disconnected)
            {
                return;
            }

            recovering = _snapshot = new SessionSnapshot(SessionState.Recovering, detail, DateTimeOffset.UtcNow);
            disconnected = _snapshot = new SessionSnapshot(SessionState.Disconnected, detail, DateTimeOffset.UtcNow);
        }

        Changed?.Invoke(this, recovering);
        Changed?.Invoke(this, disconnected);
    }

    private bool TryTransition(SessionState destination, string detail, params SessionState[] allowedFrom)
    {
        SessionSnapshot? changed = null;
        lock (_gate)
        {
            if (!allowedFrom.Contains(_snapshot.State))
            {
                return false;
            }

            changed = _snapshot = new SessionSnapshot(destination, detail, DateTimeOffset.UtcNow);
        }

        Changed?.Invoke(this, changed);
        return true;
    }
}
