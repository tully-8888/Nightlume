TEMPLATE = subdirs
SUBDIRS = \
    moonlight-common-c \
    qmdnsengine \
    h264bitstream

macx {
    SUBDIRS += app/helper
}

SUBDIRS += app

app.depends = qmdnsengine moonlight-common-c h264bitstream
macx {
    app.depends += app/helper
}

win32:!winrt {
    SUBDIRS += AntiHooking
    app.depends += AntiHooking
}

# Support debug and release builds from command line for CI
CONFIG += debug_and_release

# Run our compile tests
load(configure)
qtCompileTest(SL)
qtCompileTest(EGL)
