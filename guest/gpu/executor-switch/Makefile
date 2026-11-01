# Builds the layer (never unloaded: the loader may unload and reload a layer library while
# a device made through it lives, which would lose the layer's state) and its test against the system Vulkan headers and loader (README.md).
CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++17 -Wall -Wextra -Werror -fPIC -fvisibility=hidden

all: libVkLayer_caboose_executor_switch.so test_executor_switch test_policy

libVkLayer_caboose_executor_switch.so: executor_switch.cpp policy.h
	$(CXX) $(CXXFLAGS) -shared -Wl,-z,defs -Wl,-z,nodelete -o $@ $< -lpthread

test_executor_switch: test_executor_switch.cpp
	$(CXX) -std=c++17 -Wall -Wextra -Werror -Wno-missing-field-initializers -UNDEBUG -o $@ $< -lvulkan

test_policy: test_policy.cpp policy.h
	$(CXX) -std=c++17 -Wall -Wextra -Werror -UNDEBUG -o $@ test_policy.cpp

clean:
	rm -f libVkLayer_caboose_executor_switch.so test_executor_switch test_policy

.PHONY: all clean
