TEMPLATE = app
TARGET = com.moonlight-stream.Moonlight.helper
CONFIG -= qt
CONFIG += c++17
CONFIG -= app_bundle

OBJECTIVE_SOURCES += \
    main.m \
    MoonlightHelper.m

HEADERS += \
    MoonlightHelper.h

LIBS += -framework Foundation -framework Security

macx {
    QMAKE_LFLAGS += -sectcreate __TEXT __info_plist $$PWD/Info.plist -sectcreate __TEXT __launchd_plist $$PWD/launchd.plist
    QMAKE_CFLAGS += -fobjc-arc
    QMAKE_OBJECTIVE_CFLAGS += -fobjc-arc
}
