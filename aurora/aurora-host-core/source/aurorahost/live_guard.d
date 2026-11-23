module aurorahost.live_guard;

// ===========================================================================
// Live-window kill guard.
//
// Aurora Host owns one visible development window. The supported development
// cycle keeps that window open: scene edits reload in place, and controller
// changes restart only the controller. Rebuilding the host and force-killing
// the old process is not part of the cycle - it closes the window the developer
// was working in and loses focus, selection, and the live scene session.
//
// A window close (WM_CLOSE), the host's `close` control command, and normal
// process exit remain allowed. What this guard removes is the bypass: another
// same-user process calling TerminateProcess (for example PowerShell
// `Stop-Process -Force`, `taskkill /F`, or a build script that kills the old
// executable). It replaces the process DACL with one that denies
// PROCESS_TERMINATE to Everyone while still granting normal query/synchronize
// access, and grants SYSTEM full access so logoff and shutdown work.
//
// This is deliberately applied to the production host only. Tests, isolated
// instance groups, and an explicitly disposable run pass
// `--allow-termination`. Replacing a host-core build must use a graceful close
// or an explicit disposable launch, never a silent force-kill of the live one.
// ===========================================================================

version (Windows)
{
    import core.sys.windows.windows : ACL, AddAccessAllowedAce, AddAccessDeniedAce,
        CloseHandle, CreateWellKnownSid, DACL_SECURITY_INFORMATION, DWORD, FALSE,
        GetCurrentProcessId, InitializeAcl, InitializeSecurityDescriptor,
        OpenProcess, PACL, PSECURITY_DESCRIPTOR, PSID, SECURITY_DESCRIPTOR,
        SECURITY_DESCRIPTOR_REVISION, TRUE, WELL_KNOWN_SID_TYPE,
        SetSecurityDescriptorDacl;
    import core.sys.windows.aclapi : SetSecurityInfo;
    import core.sys.windows.accctrl : SE_OBJECT_TYPE;
    import core.sys.windows.winnt : ACL_REVISION, PROCESS_ALL_ACCESS;
    import std.conv : to;

    pragma(lib, "advapi32.lib");

    // Not all druntime releases name these in ACCESS_MASK; the values are the
    // stable Win32 process rights.
    private enum DWORD processTerminate = 0x0001;
    private enum DWORD processWriteDac = 0x00040000;
    private enum int maximumSidBytes = 68;

    /// Record the last failure for diagnostics; empty after success.
    private __gshared string _lastError = "";

    /// Why the most recent `protectLiveWindow` call failed, or "" on success.
    string liveGuardError()
    {
        return _lastError;
    }

    /**
     * Deny external forced termination of this process while leaving normal
     * close and exit paths intact. Returns false when the platform or the
     * process token cannot apply the DACL; the host still runs unprotected.
     */
    bool protectLiveWindow()
    {
        _lastError = "";
        align(8) ubyte[SECURITY_DESCRIPTOR.sizeof] descriptor;
        align(4) ubyte[256] dacl;
        align(4) ubyte[maximumSidBytes] everyone;
        align(4) ubyte[maximumSidBytes] system;
        DWORD everyoneLength = everyone.length;
        DWORD systemLength = system.length;

        if (!CreateWellKnownSid(WELL_KNOWN_SID_TYPE.WinWorldSid, null,
                cast(PSID) everyone.ptr, &everyoneLength))
        {
            _lastError = "CreateWellKnownSid(WinWorldSid) failed";
            return false;
        }
        if (!CreateWellKnownSid(WELL_KNOWN_SID_TYPE.WinLocalSystemSid, null,
                cast(PSID) system.ptr, &systemLength))
        {
            _lastError = "CreateWellKnownSid(WinLocalSystemSid) failed";
            return false;
        }
        if (!InitializeAcl(cast(PACL) dacl.ptr, dacl.length, ACL_REVISION))
        {
            _lastError = "InitializeAcl failed";
            return false;
        }
        // Deny first: a later allow ACE cannot re-grant a denied right.
        if (!AddAccessDeniedAce(cast(PACL) dacl.ptr, ACL_REVISION,
                processTerminate, cast(PSID) everyone.ptr))
        {
            _lastError = "AddAccessDeniedAce failed";
            return false;
        }
        if (!AddAccessAllowedAce(cast(PACL) dacl.ptr, ACL_REVISION,
                cast(DWORD) PROCESS_ALL_ACCESS, cast(PSID) everyone.ptr))
        {
            _lastError = "AddAccessAllowedAce(Everyone) failed";
            return false;
        }
        // SYSTEM retains full access for logoff, shutdown, and recovery.
        if (!AddAccessAllowedAce(cast(PACL) dacl.ptr, ACL_REVISION,
                cast(DWORD) PROCESS_ALL_ACCESS, cast(PSID) system.ptr))
        {
            _lastError = "AddAccessAllowedAce(SYSTEM) failed";
            return false;
        }
        if (!InitializeSecurityDescriptor(cast(PSECURITY_DESCRIPTOR)
                descriptor.ptr, SECURITY_DESCRIPTOR_REVISION))
        {
            _lastError = "InitializeSecurityDescriptor failed";
            return false;
        }
        if (!SetSecurityDescriptorDacl(cast(PSECURITY_DESCRIPTOR)
                descriptor.ptr, TRUE, cast(PACL) dacl.ptr, FALSE))
        {
            _lastError = "SetSecurityDescriptorDacl failed";
            return false;
        }
        auto process = OpenProcess(processWriteDac, FALSE,
            GetCurrentProcessId());
        if (process is null)
        {
            _lastError = "OpenProcess(PROCESS_WRITE_DAC) failed";
            return false;
        }
        scope (exit) CloseHandle(process);
        const status = SetSecurityInfo(process,
            SE_OBJECT_TYPE.SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION,
            null, null, cast(PACL) dacl.ptr, null);
        if (status != 0)
        {
            _lastError = "SetSecurityInfo failed with status " ~
                to!string(status);
            return false;
        }
        return true;
    }
}
else
{
    /// Deny external forced termination of the live window where supported.
    bool protectLiveWindow() { return false; }
    string liveGuardError() { return "not supported on this platform"; }
}
