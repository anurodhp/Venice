# venice: a small video player for GNUstep, on libmpv (see README.md).
#
# Needs libmpv (with its render API), Xlib with MIT-SHM (Xext) and libGL with
# GLX. Where they are not on the default search paths, pass the flags in, e.g.
#   make ADDITIONAL_CPPFLAGS="-I/opt/mpv/include" ADDITIONAL_LIB_DIRS="-L/opt/mpv/lib"
include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Venice
VERSION = 0.1
Venice_OBJC_FILES = main.m VeniceWindow.m VeniceView.m VenicePlayer.m VeniceControls.m
Venice_C_FILES = VeniceX.c VeniceVideoGL.c VeniceVideoSW.c
Venice_MAIN_MODEL_FILE =
Venice_APPLICATION_ICON = Venice.tiff
Venice_RESOURCE_FILES = icons/Venice.tiff icons/Venice.png
Venice_LOCALIZED_RESOURCE_FILES =

ADDITIONAL_CFLAGS += -std=gnu99 -O2 -Wall
ADDITIONAL_OBJCFLAGS += -O2 -Wall
ADDITIONAL_GUI_LIBS += -lmpv -lGL -lXext -lX11

include $(GNUSTEP_MAKEFILES)/application.make
