set dotenv-load

derived_data := ".build/xcode-derived"
configuration := "Release"
app_bundle := derived_data / "Build/Products" / configuration / "Inkstone.app"

lint:
    swiftlint lint Sources

lint-fix:
    swiftlint lint --fix Sources

format:
    swift format --recursive --in-place Sources

format-check:
    swift format lint --recursive Sources

build:
    xcodebuild -project Inkstone.xcodeproj \
        -scheme Inkstone \
        -configuration '{{ configuration }}' \
        -derivedDataPath '{{ derived_data }}' \
        -allowProvisioningUpdates \
        "CODE_SIGN_STYLE=${CODE_SIGN_STYLE:-Automatic}" \
        "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:--}" \
        "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}" \
        ONLY_ACTIVE_ARCH=YES build

clean:
    rm -rf .build

run: build
    @osascript -e 'quit app "Inkstone"' 2>/dev/null || true
    @n=0; while pgrep -x Inkstone >/dev/null 2>&1 && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
    @touch '{{ app_bundle }}'
    @'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister' -f '{{ app_bundle }}'
    @open '{{ app_bundle }}'

install: build
    @rm -rf ~/Applications/Inkstone.app
    @cp -R '{{ app_bundle }}' ~/Applications/Inkstone.app
    @echo 'Installed to ~/Applications/Inkstone.app'
