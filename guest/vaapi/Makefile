# caboose_drv_video.so, its unit tests and tools. Build in the dev container:
#   scripts/dev.sh make && scripts/dev.sh make check
VERSION := 0.1.0
CC ?= cc
PKGS := libva libdrm libavcodec libavutil
CFLAGS ?= -O2 -g
ALL_CFLAGS = $(CFLAGS) -std=gnu11 -Wall -Wextra -Wshadow -Werror=implicit-function-declaration -fvisibility=hidden \
          -fPIC -DCABOOSE_VA_VERSION='"$(VERSION)"' $(shell pkg-config --cflags $(PKGS))
LIBS := $(shell pkg-config --libs libavcodec libavutil) -lpthread -lm

BUILD ?= build
DESTDIR ?=
DRIDIR ?= $(shell pkg-config --variable=driverdir libva)
SRC := src/driver.c src/surface.c src/sink.c src/local.c src/bits.c src/marker.c \
       src/h264.c src/hevc.c src/vp9.c src/av1.c
OBJ := $(SRC:src/%.c=$(BUILD)/%.o)

all: $(BUILD)/caboose_drv_video.so $(BUILD)/unit $(BUILD)/cbva-capture $(BUILD)/cbva-detect

$(BUILD)/%.o: src/%.c src/*.h | $(BUILD)
	$(CC) $(ALL_CFLAGS) -c $< -o $@

$(BUILD)/caboose_drv_video.so: $(OBJ)
	$(CC) $(LDFLAGS) -shared -Wl,--no-undefined -Wl,-z,defs -o $@ $(OBJ) $(LIBS)

$(BUILD)/unit: tests/unit.c $(BUILD)/bits.o $(BUILD)/marker.o
	$(CC) $(ALL_CFLAGS) -Isrc -o $@ $^ -lm

$(BUILD)/cbva-capture: tools/cbva-capture.c src/proto.h | $(BUILD)
	$(CC) $(ALL_CFLAGS) -Isrc -o $@ $<

$(BUILD)/cbva-detect: tools/cbva-detect.c $(BUILD)/marker.o
	$(CC) $(ALL_CFLAGS) -Isrc -o $@ $^ -lm

$(BUILD):
	mkdir -p $(BUILD)

check: all
	$(BUILD)/unit
	CBVA_BUILD=$(BUILD) tests/roundtrip.sh

install: $(BUILD)/caboose_drv_video.so
	install -D -m 0644 $< $(DESTDIR)$(DRIDIR)/caboose_drv_video.so

clean:
	rm -rf $(BUILD)

.PHONY: all check install clean
