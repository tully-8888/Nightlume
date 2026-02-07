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
    // Windows and macOS are always running a window manager
    return true;
}

bool WMUtils::isRunningDesktopEnvironment()
{
    bool value;
    if (Utils::getEnvironmentVariableOverride("HAS_DESKTOP_ENVIRONMENT", &value)) {
        return value;
    }

    // Windows and macOS are always running a desktop environment
    return true;
}

bool WMUtils::isGpuSlow()
{
    return false;
}

QString WMUtils::getDrmCardOverride()
{
    return QString();
}
