TARGET_EXEC := occlusion

BUILD_DIR := ./build
SRC_DIR   := ./src

SRCS := $(shell find $(SRC_DIR) -name '*.cpp' -or -name '*.c' -or -name '*.cu')
OBJS := $(SRCS:%=$(BUILD_DIR)/%.o)

CC  := nvcc
CXX := nvcc
LDFLAGS += -Lusr/lib -lgdal -lgomp


$(BUILD_DIR)/$(TARGET_EXEC): $(OBJS)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS)

$(BUILD_DIR)/%.c.o: %.c
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/%.cpp.o : %.cpp
	mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/%.cu.o: %.cu
	mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@


release: CXXFLAGS += -O3 -Xcompiler -fopenmp -ftz=true -prec-div=false --use_fast_math
release: CC       += -O3 -Xcompiler -fopenmp -ftz=true -prec-div=false --use_fast_math
release: build

debug: CXXFLAGS += -g -G -Xcompiler -fopenmp
debug: CC       += -g -G -Xcompiler -fopenmp
debug: build

build: $(BUILD_DIR)/$(TARGET_EXEC)

run: build
	$(BUILD_DIR)/$(TARGET_EXEC)

clean:
	rm -r $(BUILD_DIR)