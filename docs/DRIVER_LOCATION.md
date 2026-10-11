# Driver location and road ETA

## Background location (Android foreground service / iOS background mode)

* Sharing starts only when the driver switches **Share my location** on for a run they picked up, after
  a rationale dialog (`DriverLocationTracker.backgroundRationale`) — Play and App Store require this
  prominent disclosure.
* **Android:** geolocator's foreground service (`AndroidSettings.foregroundNotificationConfig`) with a
  permanent "Sharing your delivery location" notification. Permissions: `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_LOCATION`, `WAKE_LOCK`. **No `ACCESS_BACKGROUND_LOCATION`**: the service is started
  while the app is open, so the Play "background location" declaration is not needed. In the Play
  Console declare the foreground service type *location* with the reason "a driver shares the position
  of an active delivery run with the shop and its customers".
* **iOS:** `UIBackgroundModes = location`, `allowBackgroundLocationUpdates`, blue indicator shown,
  "When in use" permission only.
* It stops when the server answers `tracking: false` (run delivered / failed / cancelled), when the
  driver switches it off, or on sign-out; the server deletes the points when the run ends.
* Must be tested on real phones (screen off for 10 minutes on Android 13/14 and iOS 17+).

## Road distance / ETA

`supabase/functions/route-eta` computes road distance and driving time branch → stops with a routing
service whose key stays in Supabase secrets (`ROUTING_PROVIDER=ors` + `ORS_API_KEY`, or
`ROUTING_PROVIDER=osrm` + `ROUTING_URL` of your own OSRM server). Only active staff, owners and drivers
may call it. The driver portal shows "8.1 km by road · about 16 min (estimate)" under the run map;
without a configured provider, or when a stop has no pin, nothing is shown (no straight-line guess is
presented as a road figure). Tests: `supabase/functions/route-eta/handler_test.ts`, `test/road_eta_test.dart`.

Deploy: `supabase functions deploy route-eta --no-verify-jwt` and set the secrets above.
