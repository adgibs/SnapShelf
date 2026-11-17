.PHONY: app run test clean

app:
	./Scripts/make-app.sh

run: app
	-pkill -x SnapShelf && sleep 1
	open build/SnapShelf.app

test:
	swift test

clean:
	rm -rf .build build
