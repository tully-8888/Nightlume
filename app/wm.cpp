#include <QtGlobal>
#include <QDir>

#include "utils.h"

#include "SDL_compat.h"

#define VALUE_SET 0x01
#define VALUE_TRUE 0x02

bool WMUtils::isRunningX11()
{
    return false;
}

bool WMUtils::isRunningNvidiaProprietaryDriverX11()
{
    return false;
}

bool WMUtils::supportsDesktopGLWithEGL()
{
    // Assume it does if we can't check ourselves
    return true;
}

bool WMUtils::isRunningWayland()
{
    return false;
}

bool WMUtils::isRunningWindowManager()
{
#if defined(Q_OS_WIN) || defined(Q_OS_DARWIN)
    // Windows and macOS are always running a window manager
    return true;
#else
    // On Unix OSes, look for Wayland or X
    return WMUtils::isRunningWayland() || WMUtils::isRunningX11();
#endif
}

bool WMUtils::isRunningDesktopEnvironment()
{
    bool value;
    if (Utils::getEnvironmentVariableOverride("HAS_DESKTOP_ENVIRONMENT", &value)) {
        return value;
    }

#if defined(Q_OS_WIN) || defined(Q_OS_DARWIN)
    // Windows and macOS are always running a desktop environment
    return true;
#else
    // On non-embedded systems, assume we have a desktop environment
    // if we have a WM running.
    return isRunningWindowManager();
#endif
}

bool WMUtils::isGpuSlow()
{
    return false;
}

QString WMUtils::getDrmCardOverride()
{
    return QString();
}
