# Security

CleanUp stops processes on your Mac, so a bug that makes it stop the wrong thing, or lets another app make it stop something, is a security issue.

## Reporting a vulnerability

Please report it privately: open the repository's **Security** tab and choose **Report a vulnerability**. Don't open a public issue for it.

Include what you saw, the steps to reproduce it, and your macOS version. You'll get a reply within a few days, and a fix or a plan within two weeks.

## What counts

- CleanUp stopping, quitting or signalling something that was in use, or something it should never touch (system processes, Finder, Dock, itself).
- Another app or a web page triggering a cleanup (for example through the widget's request) without you pressing Clean up.
- CleanUp sending anything off your Mac. It has no network access, accounts or telemetry by design.

Something ticked that you were using, but not stopped, is a normal bug: please open an issue for that.

## Supported versions

Only the latest release on `main` gets fixes.
