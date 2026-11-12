.PHONY: app run install icon demo clean

app:
	./scripts/build-app.sh

run: app
	open build/Clacky.app

install: app
	osascript -e 'quit app "Clacky"' 2>/dev/null || true
	rm -rf /Applications/Clacky.app
	cp -R build/Clacky.app /Applications/
	open /Applications/Clacky.app

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

# Renders every switch typing a sentence to build/demo/*.wav and prints levels.
demo:
	swift build -c release
	.build/release/Clacky --render-demo build/demo

clean:
	rm -rf .build build
