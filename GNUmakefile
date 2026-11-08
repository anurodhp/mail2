# mail2: a small IMAP mail client for GNUstep (see README.md).
#
# Needs libetpan (with its low-level IMAP, SMTP and MIME layers), SQLite 3, Mbed TLS 3.6 and libxml2. Where they
# are not on the default search paths, pass the flags in, e.g.
#   make ADDITIONAL_CPPFLAGS="-I/opt/etpan/include" ADDITIONAL_LIB_DIRS="-L/opt/etpan/lib"
include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Mail2
VERSION = 0.1
Mail2_OBJC_FILES = main.m Mail2Util.m Mail2Account.m Mail2Store.m Mail2IMAP.m Mail2SMTP.m Mail2Message.m \
	Mail2Session.m Mail2Views.m Mail2Window.m Mail2Compose.m Mail2AccountPanel.m Mail2OAuth.m Mail2Rules.m Mail2RulesWindow.m Mail2RichText.m Mail2Outbox.m Mail2Spell.m MilanText.m
Mail2_C_FILES = Mail2TLS.c
Mail2_MAIN_MODEL_FILE =
Mail2_APPLICATION_ICON = Mail2.tiff
Mail2_RESOURCE_FILES = icons/Mail2.tiff icons/Mail2.png $(wildcard icons/tb-*.tiff) $(wildcard icons/sb-*.tiff) dict/en_US.aff dict/en_US.dic dict/README_en_US.txt
Mail2_LOCALIZED_RESOURCE_FILES =

ADDITIONAL_CFLAGS += -std=gnu99 -O2 -Wall
ADDITIONAL_OBJCFLAGS += -O2 -Wall -fblocks
ADDITIONAL_GUI_LIBS += -letpan -lsqlite3 -lmbedtls -lmbedx509 -lmbedcrypto -lxml2 -lhunspell -liconv

include $(GNUSTEP_MAKEFILES)/application.make
