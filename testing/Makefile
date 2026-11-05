# Small apps with a CPU profile known in advance, and the targets that profile them with nusku
# and check what it found. Profiling needs root: the run targets use sudo.
#
#   make                 build nusku and the three apps
#   make profile-c       profile the C app, and show the report (also profile-go, profile-zig)
#   make check           profile all three, and check each report against its expect.txt
#   make DURATION=10 check
#   make clean

NUSKU    := ../zig-out/bin/nusku
OUT      := out
DURATION ?= 5

APPS := c go zig

.PHONY: all build nusku apps check clean $(addprefix profile-,$(APPS)) $(addprefix check-,$(APPS))

all: build
build: nusku apps

nusku:
	cd .. && zig build

apps: $(OUT)/c-app $(OUT)/go-app $(OUT)/zig-app

# -O2 leaves out frame pointers: the walk needs .eh_frame. No sibling calls, so every
# function of the chain keeps its frame.
$(OUT)/c-app: apps/c/app.c | $(OUT)
	cc -O2 -fno-optimize-sibling-calls -o $@ $<

$(OUT)/go-app: apps/go/main.go apps/go/go.mod | $(OUT)
	cd apps/go && go build -o ../../$@ .

# Zig's own linker writes no build ID unless asked, and nusku names only binaries with one.
$(OUT)/zig-app: apps/zig/main.zig | $(OUT)
	zig build-exe -O ReleaseFast --build-id=fast -femit-bin=$@ --cache-dir $(OUT)/zig-cache $<

$(OUT):
	mkdir -p $@

# The report on the terminal, and the stacks in out/<app>.folded for `check` (and for flame
# graph tools: `flamegraph.pl out/c.folded > c.svg`).
$(addprefix profile-,$(APPS)): profile-%: build
	sudo $(NUSKU) prof --exec $(OUT)/$*-app --duration $(DURATION) \
		--folded $(OUT)/$*.folded --color always

$(addprefix check-,$(APPS)): check-%: profile-%
	@echo "== $* app"
	@./check.sh $(OUT)/$*.folded apps/$*/expect.txt

# Every app is checked, even after one fails; the target fails if any did.
check: build
	@failed=0; \
	for app in $(APPS); do \
		$(MAKE) --no-print-directory check-$$app DURATION=$(DURATION) \
			> $(OUT)/$$app.log 2>&1 || failed=1; \
		sed -n '/^== /,$$p' $(OUT)/$$app.log; \
	done; \
	exit $$failed

clean:
	rm -rf $(OUT)
