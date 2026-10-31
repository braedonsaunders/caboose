# vgem_gbm.so, the GBM backend for the Caboose render node, and its test.
#   make            build/vgem_gbm.so and build/gbm_test
#   make check      run the test against the machine's vgem render node (skips without one)
#   make install    into libgbm's backend directory ($(GBMDIR)); DESTDIR is honoured
CC ?= cc
CFLAGS ?= -O2 -g
ALL_CFLAGS = $(CFLAGS) -std=gnu11 -Wall -Wextra -Wshadow -Werror -fvisibility=hidden -fPIC -Iinclude \
             $(shell pkg-config --cflags libdrm) $(shell pkg-config --cflags gbm 2>/dev/null)
BUILD ?= build
DESTDIR ?=
GBMDIR ?= $(shell pkg-config --variable=libdir gbm)/gbm

all: $(BUILD)/vgem_gbm.so $(BUILD)/gbm_test

$(BUILD)/vgem_gbm.so: src/vgem_gbm.c include/*.h | $(BUILD)
	$(CC) $(ALL_CFLAGS) $(LDFLAGS) -shared -Wl,--no-undefined -Wl,-z,defs -o $@ $< \
	  $(shell pkg-config --libs libdrm) -lpthread

$(BUILD)/gbm_test: tests/gbm_test.c include/caboose_drm_formats.h | $(BUILD)
	$(CC) $(ALL_CFLAGS) -o $@ $< $(shell pkg-config --cflags --libs gbm libdrm)

check: all
	GBM_BACKENDS_PATH=$(abspath $(BUILD)) $(BUILD)/gbm_test

install: $(BUILD)/vgem_gbm.so
	install -D -m 0644 $(BUILD)/vgem_gbm.so $(DESTDIR)$(GBMDIR)/vgem_gbm.so

$(BUILD):
	mkdir -p $(BUILD)

.PHONY: all check install
