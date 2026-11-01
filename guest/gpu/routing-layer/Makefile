# Builds the layer (never unloaded: the loader may unload and reload a layer library while
# a device made through it lives, which would lose the layer's state) and its test against the system Vulkan headers (README.md).
CXXFLAGS ?= -O2 -g
override CXXFLAGS += -std=c++17 -Wall -Wextra -Werror -fPIC -fvisibility=hidden

all: libVkLayer_caboose_gpu_routing.so test_routing

libVkLayer_caboose_gpu_routing.so: routing_layer.cpp routing.h
	$(CXX) $(CXXFLAGS) -shared -Wl,-z,defs -Wl,-z,nodelete -o $@ routing_layer.cpp -lpthread

test_routing: test_routing.cpp routing.h
	$(CXX) -std=c++17 -Wall -Wextra -Werror -UNDEBUG -o $@ test_routing.cpp

clean:
	rm -f libVkLayer_caboose_gpu_routing.so test_routing

.PHONY: all clean
