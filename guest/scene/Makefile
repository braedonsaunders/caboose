# Makefile — Caboose Guest Scene Graph Interceptor & WSI Promotion Layer

CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -fPIC -pthread
LDFLAGS ?= -pthread

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    SHARED_FLAGS := -dynamiclib
    DL_LIBS      :=
else
    SHARED_FLAGS := -shared
    DL_LIBS      := -ldl
endif

BUILD_DIR := build
CAIRO_SO  := $(BUILD_DIR)/libcaboose_scene_cairo.so
WSI_SO    := $(BUILD_DIR)/libcaboose_wsi_promote.so
TEST_BIN  := $(BUILD_DIR)/test_scene_wire

.PHONY: all check clean install

all: $(CAIRO_SO) $(WSI_SO) $(TEST_BIN)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(CAIRO_SO): src/caboose_scene_cairo.c src/scene_wire.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SHARED_FLAGS) -o $@ src/caboose_scene_cairo.c $(LDFLAGS) $(DL_LIBS)

$(WSI_SO): wsi/caboose_wsi_promote.c src/scene_wire.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SHARED_FLAGS) -o $@ wsi/caboose_wsi_promote.c $(LDFLAGS) $(DL_LIBS)

$(TEST_BIN): tests/test_scene_wire.c src/caboose_scene_cairo.c wsi/caboose_wsi_promote.c src/scene_wire.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ tests/test_scene_wire.c src/caboose_scene_cairo.c wsi/caboose_wsi_promote.c $(LDFLAGS) $(DL_LIBS) -lm

check: $(TEST_BIN) $(CAIRO_SO) $(WSI_SO)
	./$(TEST_BIN)

clean:
	rm -rf $(BUILD_DIR)
