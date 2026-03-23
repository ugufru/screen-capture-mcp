.PHONY: build clean rebuild

build:
	@mkdir -p cpp/build
	@cd cpp/build && cmake .. && make -j$(sysctl -n hw.ncpu)

clean:
	@rm -rf cpp/build

rebuild: clean build
