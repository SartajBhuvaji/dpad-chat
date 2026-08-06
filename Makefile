# D-Pad Chat
#
# The default target is the check developers run before pushing. Everything
# here works without Docker; the -docker variants reproduce the device's
# busybox userland, which is where POSIX mistakes actually surface.

SHELL := /bin/sh
IMAGE := dpad-chat-test
CARD  ?=
HOST  ?=
# Onion's documented login. USER is a shell builtin in make, so it is renamed.
USER_ ?= onion

.PHONY: help check lint test mock sim icon docker-build test-docker shell-docker install install-ssh clean

help:
	@echo 'Targets:'
	@echo '  check         lint + smoke tests (default)'
	@echo '  lint          POSIX syntax, shellcheck, JSON'
	@echo '  test          smoke tests + API tests against the mock server'
	@echo '  mock          run the mock API on :8080 for manual poking'
	@echo '  sim           run the app locally at 40 columns'
	@echo '  icon          regenerate app/res/icon.png'
	@echo '  test-docker   run check inside the Alpine harness'
	@echo '  shell-docker  interactive busybox ash in the harness'
	@echo '  install       copy to an SD card    (make install CARD=/media/me/MIYOO)'
	@echo '  install-ssh   push over SSH         (make install-ssh HOST=192.168.1.42 [USER=onion])'
	@echo '  clean         remove local run state'

check: lint test

lint:
	@tools/lint.sh

test:
	@tests/smoke.sh
	@tests/api.sh

sim:
	@tools/simulate.sh

mock:
	@tools/mockapi.py --port 8080 --verbose

icon:
	@python3 tools/make_icon.py

docker-build:
	@docker build -t $(IMAGE) .

test-docker: docker-build
	@docker run --rm $(IMAGE)

shell-docker: docker-build
	@docker run --rm -it $(IMAGE) -l

install:
	@test -n '$(CARD)' || { echo 'usage: make install CARD=/path/to/sdcard' >&2; exit 1; }
	@tools/install.sh '$(CARD)'

install-ssh:
	@test -n '$(HOST)' || { echo 'usage: make install-ssh HOST=<ip> [USER=onion]' >&2; exit 1; }
	@DPAD_SSH_USER='$(USER_)' tools/install.sh --ssh '$(HOST)'

clean:
	@rm -rf app/data
	@echo 'Removed app/data'
