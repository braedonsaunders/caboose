/* check-rotation.sh's program: per-monitor DPI-aware, it asks the screen size and each
 * monitor's raw DPI every half second for 20 s. */
#include <windows.h>
#include <shellscalingapi.h>
#include <stdio.h>

static BOOL CALLBACK monitor(HMONITOR handle, HDC dc, LPRECT rect, LPARAM unused)
{
    UINT x = 0, y = 0;
    GetDpiForMonitor(handle, MDT_RAW_DPI, &x, &y);
    printf(" raw dpi %u %u", x, y);
    return TRUE;
}

int main(void)
{
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    for (int i = 0; i < 40; i++)
    {
        MSG msg;
        while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        printf("screen %dx%d", GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        EnumDisplayMonitors(NULL, NULL, monitor, 0);
        printf("\n");
        fflush(stdout);
        Sleep(500);
    }
    return 0;
}
