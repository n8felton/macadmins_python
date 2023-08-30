SHELL := /bin/zsh
ifndef TYPE
  TYPE ?= minimal
  $(info TYPE is not set. Defaulting to "$(TYPE)".)
endif
ifndef PYTHON_VERSION
  PYTHON_VERSION ?= 3.11.1
  $(info PYTHON_VERSION is not set. Defaulting to "$(PYTHON_VERSION)")
endif
ifndef DEV_APPLICATION_ID
  DEV_APPLICATION_ID ?= -
  $(info DEV_APPLICATION_ID is not set. Try `export DEV_APPLICATION_ID="Developer ID Application: <CORP>"`)
endif
ifndef DEV_INSTALLER_ID
  DEV_APPLICATION_ID ?= -
  $(info DEV_INSTALLER_ID is not set. Try `export DEV_INSTALLER_ID="Developer ID Installer: <CORP>"`)
endif

BREW_BIN := $(shell which brew)
BREW_LIST = $(shell $(BREW_BIN) list)
CONSOLEUSER := $(/usr/bin/stat -f "%Su" /dev/console)
MKDIR = @mkdir -p "$(@D)"

RP_SHA := fb4dd9b024b249c71713f14d887f4bcea78aa8b0
RP_DIR := /tmp/relocatable-python

VERS       := $(subst ., ,$(PYTHON_VERSION))
VERS_MAJOR := $(word 1,$(VERS))
VERS_MINOR := $(word 2,$(VERS))
VERS_PATCH := $(word 3,$(VERS))

PYTHON_BIN_VERSION := $(VERS_MAJOR).$(VERS_MINOR)
NEWSUBBUILD := $(shell expr 80620 + $$(git rev-list HEAD~0 --count))
PYTHON_BUILD_VERSION := $(PYTHON_VERSION).$(NEWSUBBUILD)
MACOS_VERSION := 11
PYTHON_BASEURL := "https://www.python.org/ftp/python/%s/python-%s-macos%s.pkg"

BUILD_DIR := build
PAYLOAD_PATH := $(BUILD_DIR)/$(TYPE)/payload
MANAGEDFRAMEWORKS_PYTHON_PATH := /Library/ManagedFrameworks/Python
PAYLOAD_MANAGEDFRAMEWORKS_PYTHON_PATH := $(PAYLOAD_PATH)/$(MANAGEDFRAMEWORKS_PYTHON_PATH)
PAYLOAD_PYTHON_VERS_PATH := $(PAYLOAD_MANAGEDFRAMEWORKS_PYTHON_PATH)/Python3.framework/Versions/$(PYTHON_BIN_VERSION)
PYTHON_BIN := $(MANAGEDFRAMEWORKS_PYTHON_PATH)/Python3.framework/Versions/Current/bin/python3

OUTPUT_DIR := output
OUTPUT_PKG_NAME := python_$(TYPE)-$(PYTHON_BUILD_VERSION)
OUTPUT_PKG_PATH := $(OUTPUT_DIR)/$(OUTPUT_PKG_NAME)

PYTHON_BIN_FILES = $(shell /usr/bin/find "$(PAYLOAD_PYTHON_VERS_PATH)/bin" -type f -perm -u=x 2>/dev/null)
PYTHON_BIN_FILES += $(PAYLOAD_PYTHON_VERS_PATH)/Python
PYTHON_BIN_FILES += $(PAYLOAD_PYTHON_VERS_PATH)/Resources/Python.app/Contents/MacOS/Python
PYTHON_LIB_FILES = $(shell /usr/bin/find "$(PAYLOAD_PYTHON_VERS_PATH)/lib" -type f -perm -u=x 2>/dev/null)
PYTHON_DYLIB_FILES = $(shell /usr/bin/find "$(PAYLOAD_PYTHON_VERS_PATH)/lib" -type f -name '*.dylib' 2>/dev/null)
PYTHON_SO_FILES = $(shell /usr/bin/find "$(PAYLOAD_PYTHON_VERS_PATH)/lib" -type f -name '*.so' 2>/dev/null)

.PHONY: all
all: clean build
	$(MAKE) verify-universal codesign verify-codesign pkgbuild productsign

.PHONY: dependabot
dependabot: clean build verify-universal
	$(MAKE) verify-universal

.PHONY: build
build: $(PAYLOAD_MANAGEDFRAMEWORKS_PYTHON_PATH)/Python3.framework

$(PAYLOAD_MANAGEDFRAMEWORKS_PYTHON_PATH)/Python3.framework: $(MANAGEDFRAMEWORKS_PYTHON_PATH) $(RP_DIR)/make_relocatable_python_framework.py requirements_$(TYPE).txt
	$(MKDIR)
	@C_INCLUDE_PATH="$(MANAGEDFRAMEWORKS_PYTHON_PATH)/Python.framework/Versions/$(PYTHON_BIN_VERSION)/Headers" \
	$(RP_DIR)/make_relocatable_python_framework.py \
	--baseurl "$(PYTHON_BASEURL)" \
	--python-version "$(PYTHON_VERSION)" \
	--os-version "$(MACOS_VERSION)" \
	--upgrade-pip \
	--pip-requirements requirements_$(TYPE).txt \
	--destination "$(MANAGEDFRAMEWORKS_PYTHON_PATH)"
	@/usr/bin/ditto "$(MANAGEDFRAMEWORKS_PYTHON_PATH)/Python.framework" "$(PAYLOAD_MANAGEDFRAMEWORKS_PYTHON_PATH)/Python3.framework"
	@echo "PYTHON_BUILD_VERSION=$(PYTHON_BUILD_VERSION)" >> $$GITHUB_ENV

.PHONY: verify-universal
verify-universal: $(PYTHON_BIN_FILES) $(PYTHON_LIB_FILES) $(PYTHON_DYLIB_FILES) $(PYTHON_SO_FILES)
	$(info Verifying files are Universal)
	@/usr/bin/file $^ | /usr/bin/grep "2 architectures" 1>/dev/null || (echo "Not all files are Universal"; exit $$?)
	$(info $(words $^) files found and verified as Universal)

.PHONY: codesign
codesign: $(PYTHON_BIN_FILES) $(PYTHON_LIB_FILES) $(PYTHON_DYLIB_FILES) $(PYTHON_SO_FILES)
	@/usr/bin/codesign \
	--force \
	--preserve-metadata=identifier,entitlements,flags,runtime \
	--timestamp \
	--sign "$(DEV_APPLICATION_ID)" \
	$^

.PHONY: verify-codesign
verify-codesign: $(lastword $(PYTHON_BIN_FILES)) $(lastword $(PYTHON_LIB_FILES)) $(lastword $(PYTHON_DYLIB_FILES)) $(lastword $(PYTHON_SO_FILES))
	@/usr/bin/codesign \
	--display \
	--verbose=2 \
	-r- \
	$^
	@/usr/bin/codesign \
	--verify \
	--verbose=2 \
	$^

.PHONY: pkgbuild
pkgbuild: $(OUTPUT_PKG_PATH)-build.pkg

$(OUTPUT_PKG_PATH)-build.pkg: $(PAYLOAD_MANAGEDFRAMEWORKS_PYTHON_PATH)/Python3.framework
	@$(MKDIR)
	@mkdir -p $(PAYLOAD_PATH)/usr/local/bin/
	@/bin/ln -s $(PYTHON_BIN) $(PAYLOAD_PATH)/usr/local/bin/managed_python3
	@/usr/bin/sudo /usr/sbin/chown -R ${CONSOLEUSER}:wheel $(PAYLOAD_PATH)
	@/usr/bin/pkgbuild \
	--analyze \
	--root $(PAYLOAD_PATH) \
	/private/tmp/managed_python_component.plist
	
	@/usr/bin/pkgbuild \
	--component-plist /private/tmp/managed_python_component.plist \
	--identifier io.macadmins.python.$(TYPE) \
	--install-location / \
	--ownership recommended \
	--root $(PAYLOAD_PATH) \
	--version $(PYTHON_BUILD_VERSION) \
	"$(OUTPUT_PKG_PATH)-build.pkg"

.PHONY: productsign
productsign: $(OUTPUT_PKG_PATH).pkg

$(OUTPUT_PKG_PATH).pkg: $(OUTPUT_PKG_PATH)-build.pkg
	/usr/bin/productsign \
	--timestamp \
	--sign "$(DEV_INSTALLER_ID)" \
	"$(OUTPUT_PKG_PATH)-build.pkg" \
	"$(OUTPUT_PKG_PATH).pkg"

$(MANAGEDFRAMEWORKS_PYTHON_PATH):
	@/usr/bin/sudo /bin/mkdir -p -m 777 "$(@D)"

$(RP_DIR)/make_relocatable_python_framework.py:
	@$(MKDIR)
	@/usr/bin/curl -Ls -o /tmp/relocatable-python.tar.gz https://api.github.com/repos/gregneagle/relocatable-python/tarball/${RP_SHA}
	@/usr/bin/tar -xz --strip-components=1 -C $(RP_DIR) -f /tmp/relocatable-python.tar.gz


.PHONY: clean clean_pip_cache clean_MANAGEDFRAMEWORKS_PYTHON_PATH clean_brew clean_github_env
clean: clean_pip_cache clean_MANAGEDFRAMEWORKS_PYTHON_PATH clean_brew clean_github_env
	$(info Removing $(BUILD_DIR) directory)
	@rm -rf $(BUILD_DIR)
	$(info Removing $(RP_DIR) directory)
	@rm -rf $(RP_DIR)
	$(info Removing $(OUTPUT_DIR) directory)
	@rm -rf $(OUTPUT_DIR)

clean_pip_cache:
	$(info Removing pip cache to reduce framework build errors)
	@/bin/rm -rf "${HOME}/Library/Caches/pip"

clean_MANAGEDFRAMEWORKS_PYTHON_PATH:
	$(info Removing any existing Python.framework)
	@/usr/bin/sudo /bin/rm -rf $(MANAGEDFRAMEWORKS_PYTHON_PATH)/Python.framework

clean_brew:
ifdef CI
	@$(BREW_BIN) remove $(BREW_LIST)
endif

clean_github_env:
ifndef CI
	@/bin/rm -rf /tmp/GITHUB_ENV
	@export GITHUB_ENV=/tmp/GITHUB_ENV 
endif
