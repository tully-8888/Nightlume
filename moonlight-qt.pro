TEMPLATE = subdirs
SUBDIRS = \
    moonlight-common-c \
    qmdnsengine \
    h264bitstream \
    app/helper \
    app

app.depends = qmdnsengine moonlight-common-c h264bitstream app/helper

# Support debug and release builds from command line for CI
CONFIG += debug_and_release
