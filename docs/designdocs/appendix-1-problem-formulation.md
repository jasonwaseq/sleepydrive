# Appendix 1 — Problem Formulation

---

## 1.1 Conceptualisations

### Initial Concept

The core idea is a compact, vehicle-mounted device that uses a camera to continuously monitor the driver's face. When signs of drowsiness are detected (prolonged eye closure, high blink rate), the system immediately alerts the driver through their smartphone. The system must operate with minimal latency.

### Key Constraints Identified Early

- **Real-time performance:** Detection-to-alert latency must be low enough that the driver is warned before a dangerous situation develops.
- **Edge inference:** Processing must happen locally on the device to avoid dependency on cellular connectivity.
- **Lighting variability:** The system must function at night and in low-light conditions, requiring built-in IR camera support.
- **Non-intrusive:** The system should not distract the driver or require interaction while driving.
- **Cross-platform mobile app:** The alert interface must work on both iOS and Android.
- **Cost:** The total hardware cost should remain feasible for consumer or fleet deployment.

### Conceptual System Overview

```
IR Camera (input) ───> Computer (ML inference) ────> MQTT Broker (Backend) ────> App (alert)
```

---

## 1.2 Brainstorming

The team conducted brainstorming sessions to explore the design space across four major dimensions: hardware platform, ML approach, communication protocol, and mobile app framework. The following captures the ideas generated in each area.

### Hardware Platform Options

| Option | Pros | Cons |
|--------|------|------|
| **NVIDIA Jetson Orin Nano** | 20–40 TOPS, TensorRT optimization, GPU-accelerated inference, mature JetPack SDK | Higher power draw (~7–15W), larger form factor, higher cost (~$200–$500) |
| **Raspberry Pi 5** | Low cost (~$80), large community, compact | No GPU acceleration for DNN inference, limited to CPU/TPU add-ons, slower inference |
| **ESP32 + external camera** | Ultra-low cost, ultra-low power | Insufficient compute for real-time DNN inference, not viable for this application |
| **Smartphone-only (no external hardware)** | Zero additional hardware | Battery drain, camera positioning challenges, limited ML performance, thermal throttling |

### ML Model / Framework Options

| Option | Pros | Cons |
|--------|------|------|
| **MediaPipe Face Mesh** | Lightweight, well-documented, 468 facial landmarks | Less accurate for extreme head poses, may need supplementary model for yawning |
| **Custom CNN (eye state classifier)** | Can be trained on domain-specific data, potentially highest accuracy | Requires labeled training data, longer development time |
| **YOLO-Face + landmark regression** | Single-shot detection, fast, GPU-friendly | Heavier model, may be overkill for single-face in-cabin use |
| **DeepStream pipeline (NVIDIA)** | Optimized for Jetson, handles video decode + inference pipeline | Steeper learning curve, vendor lock-in |

### Communication Protocol Options

| Option | Pros | Cons |
|--------|------|------|
| **MQTT + WebSocket gateway** | Lightweight pub/sub, decoupled architecture, persistent backend storage, scalable | Requires backend infrastructure, more complex setup |
| **Direct WebSocket (Jetson → phone)** | Simple, low latency, bidirectional | Requires Jetson hotspot or shared network, no data persistence |
| **BLE (Bluetooth Low Energy)** | No network needed, auto-pairs, very low power | Limited bandwidth, shorter range, no data persistence |

### Mobile App Framework Options

| Option | Pros | Cons |
|--------|------|------|
| **Flutter** | Single codebase for iOS + Android, rich UI toolkit, Dart is easy to pick up, strong community | Larger app binary, Dart ecosystem smaller than JS |
| **React Native** | Large community, JavaScript-based, many libraries | Performance overhead via JS bridge, inconsistent native module support |
| **Native (Swift + Kotlin)** | Best performance, full platform API access | Two separate codebases, doubles development effort |

---

## 1.3 Decision Tables

The team used weighted decision matrices to evaluate alternatives across the four major design dimensions. Criteria were weighted based on project priorities (safety-critical real-time performance, development feasibility within two quarters, and cost).

### Decision Table 1: Hardware Platform

| Criteria (weight) | Jetson Orin Nano | RPi 5 | ESP32 |
|--------------------|:---:|:---:|:---:|
| **ML inference speed (0.30)** | 5 | 2 | 1 |
| **Power efficiency (0.10)** | 3 | 4 | 5 |
| **Cost (0.15)** | 2 | 4 | 5 |
| **SDK / tooling (0.20)** | 5 | 4 | 2 |
| **Camera/sensor support (0.15)** | 5 | 4 | 2 |
| **Community / documentation (0.10)** | 4 | 5 | 4 |
| **Weighted Total** | **4.15** | **3.40** | **2.45** |

**Decision:** Jetson Orin Nano — the GPU-accelerated inference and TensorRT support are critical for achieving real-time performance on a DNN-based detection pipeline.

### Decision Table 2: Communication Protocol

| Criteria (weight) | MQTT + WS Gateway | Direct WebSocket | BLE |
|--------------------|:---:|:---:|:---:|
| **Latency (0.25)** | 4 | 5 | 4 |
| **Reliability (0.25)** | 5 | 3 | 3 |
| **Data persistence (0.15)** | 5 | 1 | 1 |
| **Offline capability (0.15)** | 4 | 4 | 5 |
| **Implementation complexity (0.10)** | 2 | 4 | 3 |
| **Scalability (0.10)** | 5 | 2 | 2 |
| **Weighted Total** | **4.15** | **3.30** | **3.10** |

**Decision:** MQTT uplink + backend consumers + Postgres + WebSocket gateway downlink. This architecture provides the best balance of reliability, data persistence, and real-time alert delivery. The Jetson publishes telemetry and alerts to an MQTT broker. Backend consumer services subscribe to those messages, process them, and store results in Postgres. The Flutter app connects to a WebSocket gateway that reads the latest updates from the backend and pushes them to users in real time. The system is hosted on a static IP behind a domain.

### Decision Table 3: Mobile App Framework

| Criteria (weight) | Flutter | React Native | Native (Swift+Kotlin) |
|--------------------|:---:|:---:|:---:|
| **Cross-platform from single codebase (0.30)** | 5 | 4 | 1 |
| **Development speed (0.25)** | 5 | 4 | 2 |
| **Performance (0.15)** | 4 | 3 | 5 |
| **Team familiarity (0.20)** | 4 | 3 | 2 |
| **Library ecosystem for BLE/WS (0.10)** | 4 | 4 | 5 |
| **Weighted Total** | **4.55** | **3.65** | **2.40** |

**Decision:** Flutter — delivers cross-platform support from a single Dart codebase with strong WebSocket and notification libraries.

### Decision Table 4: ML Model / Framework

| Criteria (weight) | MediaPipe + EAR | Custom CNN | YOLO-Face |
|--------------------|:---:|:---:|:---:|
| **Inference speed (0.30)** | 4 | 4 | 3 |
| **Accuracy (0.25)** | 4 | 3 | 3 |
| **Integration with Jetson (0.20)** | 4 | 3 | 4 |
| **Development effort (0.15)** | 4 | 1 | 4 |
| **Documentation (0.10)** | 5 | 1 | 4 |
| **Weighted Total** | 4.10 | 2.80 | 3.45 |

**Decision:** MediaPipe Face Mesh with EAR (Eye Aspect Ratio) calculation - provides reliable, real-time detection of eye closure with minimal computational overhead, making it well-suited for edge deployment.

---

## 1.4 Morphological Chart

The morphological chart below maps each functional requirement of the system to the design alternatives considered, with the **selected option highlighted in bold**.

| Function | Option A | Option B | Option C | Option D |
|----------|----------|----------|----------|----------|
| **Compute platform** | **Jetson Orin Nano** | Raspberry Pi 5 | RPi + Coral TPU | ESP32 |
| **Camera type** | USB webcam (visible light) | **IR camera (night-capable)** | Stereo depth camera | Smartphone camera |
| **Face detection** | MediaPipe Face Detector | dlib HOG detector | YOLO-Face | Haar Cascades |
| **Drowsiness metric** | **EAR (Eye Aspect Ratio)** | PERCLOS | Head pose estimation | Blink frequency |
| **Fatigue classification** | Threshold-based (EAR < value) | **Temporal analysis (EAR over sliding window)** | CNN binary classifier | Hybrid (threshold + CNN) |
| **Jetson → backend comm** | **MQTT publish** | HTTP POST | Direct WebSocket | BLE |
| **Backend storage** | **PostgreSQL** | MongoDB | SQLite | Redis |
| **Backend → app comm** | **WebSocket gateway** | FCM push | Polling (HTTP) | Server-Sent Events |
| **Mobile framework** | **Flutter** | React Native | Native iOS + Android | Kotlin Multiplatform |
| **Alert modality** | Visual popup only | **Audio alarm + vibration + visual** | Haptic wearable | Seat vibration motor |
| **Power source** | **Vehicle 12V (via adapter)** | USB battery bank | Hardwired to OBD-II | Solar + battery |
| **Mounting** | Dashboard mount | **Visor/mirror mount** | A-pillar clip | Rearview mirror replacement |


The selected path through the morphological chart (bold entries) represents the team's final design: a Jetson Orin Nano with an IR camera performing EAR-based drowsiness detection over a sliding temporal window, communicating alerts via MQTT to a backend that persists data in Postgres and pushes real-time alerts through a WebSocket gateway to a cross-platform Flutter app that uses audio, vibration, and visual alerts to wake the driver.
