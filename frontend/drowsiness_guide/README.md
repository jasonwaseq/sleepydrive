# drowsiness_guide

This is the App that will display the nearby rest-stops

## Realtime Gateway WebSocket Alerts

The app listens for real-time alerts from the backend gateway websocket:

- `ws://<gateway-host>:8080/ws/alerts`

Set the URL at run time:

```bash
flutter run --dart-define=JETSON_WS_URL=ws://<gateway-host>:8080/ws/alerts
```

For public internet access, use TLS:

```bash
flutter run --dart-define=JETSON_WS_URL=wss://<your-domain>/ws/alerts
```

TODO:
- Display nearby rest stops
- Redirect to Google Maps
- Add weather data

Backloog:
- Add Apple Maps functionality
