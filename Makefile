BIN=overlay.sh

all: install

install:
ifneq ($(shell id -u), 0)
	@echo "You must be root"
else
	cp $(BIN) /usr/local/bin/$(BIN)
	chmod +x /usr/local/bin/$(BIN)
endif

uninstall:
ifneq ($(shell id -u), 0)
	@echo "You must be root"
else
	rm -f /usr/local/bin/$(BIN)
endif

