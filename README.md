# CalSync

I wanted my calendars to stop stepping on each other. The usual route is OAuth against every account, which means registering an app with each provider and, for some accounts, waiting on an admin to approve it. Apple Calendar already had everything signed in though, so this is a small menu bar app that goes through Calendar (EventKit) instead.

## What does it do?

You tick the calendars you want, and every ticked calendar's events show up in the others as untitled "Busy" blocks for the next 60 days. No titles, notes, locations or attendees, so nothing from one place leaks into the other. All-day, free, cancelled and declined events are skipped.

It syncs when a calendar changes (after a short delay), every hour, and when you press Sync now. Nothing gets written until two or more calendars are ticked. If you untick one, it asks first, then removes the blocks that calendar created and the ones inside it.

## Which calendars does it work with?

Anything Apple Calendar can sync and write to. In macOS that's the account types under Internet Accounts:

- iCloud
- Google (Workspace accounts too)
- Microsoft Exchange, which as far as I know also covers Microsoft 365 and Outlook.com
- Yahoo and AOL
- Any CalDAV server (Fastmail, Nextcloud, Synology, Zoho...)

I've only tried Google, Exchange and iCloud, so the rest is me trusting Apple's list. Read-only calendars (subscribed ICS links, birthdays, holidays) don't show up in the picker, since the app has to be able to write to them.

## Building it

You need macOS 14 or later and the Command Line Tools (no Xcode).

```
./build.sh
cp -R build/CalSync.app ~/Applications/
```

`build.sh` signs with a self-signed certificate if you put its SHA-1 in `.signing-hash`. Without one it signs ad hoc, which works, but macOS asks for calendar access again after every rebuild because the signature changes. That's why I made a certificate.

## How does it remember what it made?

Each block carries a `calsync:v2|...` line in its notes: source calendar, target calendar, event ID and start time. There's no database. Every run reads those back and works out what to create, move or delete.

The planning lives in `Engine.swift` as a plain function, and `CalSync --selftest` checks it. `CalSync --dry-run --select "Account/Calendar,Account/Calendar"` prints what it would do against your real calendars without writing anything.

## What it can't do

- Mark the blocks private. EventKit has no way to set that.
- Sync while the Mac is asleep or the app is closed.
- I've only tried it with a handful of calendars, so I'm not sure how it behaves with ten.
