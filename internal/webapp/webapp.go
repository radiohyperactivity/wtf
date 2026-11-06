// Package webapp holds the web app (the Flutter web build in app/) when
// wtfd is built with it: with the build tag "webapp", and the build copied
// to internal/webapp/dist first, as scripts/build.sh does. Without the tag,
// Files is nil, and wtfd serves the web app only from --web-root.
package webapp
