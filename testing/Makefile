# Small apps with a CPU profile known in advance, and the targets that profile them with nusku
# and check what it found. Profiling needs root: the run targets use sudo.
#
#   make                 build nusku and the three apps
#   make profile-c       profile the C app, and show the report (also -go, -zig, -threads)
#   make check           profile every app, and check each report against its expect.txt;
#                        then a target that exits before the duration
#   make DURATION=10 check
#   make clean

NUSKU    := ../zig-out/bin/nusku
OUT      := out
DURATION ?= 5
# How the profiling runs get root: `make check SUDO="sudo -A"` with an askpass helper, for one.
SUDO     ?= sudo

APPS := c go zig threads

.PHONY: all build nusku apps check check-exit clean \
	$(addprefix profile-,$(APPS)) $(addprefix check-,$(APPS))

all: build
build: nusku apps

# What users run: a debug build parses the kernel's symbols several times slower, and a short
# run would end before they are named.
nusku:
	cd .. && zig build -Doptimize=ReleaseSafe

apps: $(addprefix $(OUT)/,$(addsuffix -app,$(APPS)))

# -O2 leaves out frame pointers: the walk needs .eh_frame. No sibling calls, so every
# function of the chain keeps its frame.
$(OUT)/c-app: apps/c/app.c | $(OUT)
	cc -O2 -fno-optimize-sibling-calls -o $@ $<

$(OUT)/threads-app: apps/threads/app.c | $(OUT)
	cc -O2 -fno-optimize-sibling-calls -pthread -o $@ $<

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
	$(SUDO) $(NUSKU) prof --exec $(OUT)/$*-app --duration $(DURATION) \
		--folded $(OUT)/$*.folded --color always

$(addprefix check-,$(APPS)): check-%: profile-%
	@echo "== $* app"
	@./check.sh $(OUT)/$*.folded apps/$*/expect.txt $(DURATION)

# A target that exits before the duration: the C app, told to run 3 s, profiled for 10. The run
# must stop with it, and have its 3 s of samples: none lost at its start (it waits, stopped,
# until sampling begins), none made up after its end.
EXIT_SECONDS := 3
check-exit: build
	$(SUDO) $(NUSKU) prof --duration 10 --folded $(OUT)/exit.folded --color never \
		--exec $(OUT)/c-app $(EXIT_SECONDS) > $(OUT)/exit.txt
	@echo "== exit before the duration"
	@if grep -q "process exited" $(OUT)/exit.txt; then \
		echo "  pass  stopped when the process exited"; \
	else \
		echo "  FAIL  stopped when the process exited  (the report says otherwise)"; exit 1; \
	fi
	@./check.sh $(OUT)/exit.folded apps/c/expect.txt $(EXIT_SECONDS)

# Every check runs, even after one fails; the target fails if any did.
check: build
	@failed=0; \
	for app in $(APPS) exit; do \
		$(MAKE) --no-print-directory check-$$app DURATION=$(DURATION) \
			> $(OUT)/$$app.log 2>&1 || failed=1; \
		sed -n '/^== /,$$p' $(OUT)/$$app.log; \
	done; \
	exit $$failed

clean:
	rm -rf $(OUT)
