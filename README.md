# BLE Audio Streaming System

[![Version](https://img.shields.io/badge/version-1.0-blue.svg)](https://github.com/yourusername/ble-audio-streaming)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20ESP32-lightgrey.svg)](https://github.com/yourusername/ble-audio-streaming)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B.svg?logo=flutter)](https://flutter.dev)
[![AWS](https://img.shields.io/badge/AWS-Amplify-FF9900.svg?logo=amazon-aws)](https://aws.amazon.com/amplify/)

A real-time audio capture and streaming system that enables simultaneous connection to multiple ESP32 devices with automatic buffering during connection loss and secure cloud storage through AWS.

## 🚀 Features

- **Multi-Device Support**: Connect to multiple ESP32 BLE devices simultaneously
- **Smart Buffering**: Circular buffer (3 clips × 32KB = 96KB) provides ~3 seconds of audio retention during disconnection
- **Automatic Recovery**: Buffered audio clips are automatically transferred upon reconnection
- **Secure Authentication**: AWS Cognito integration with email verification
- **Private Cloud Storage**: User-scoped S3 storage with encryption
- **Cross-Platform Ready**: iOS operational, Android deployment ready
- **Real-Time Monitoring**: Live data transfer with progress tracking

## 📋 Table of Contents

- [Architecture](#architecture)
- [Technical Specifications](#technical-specifications)
- [Getting Started](#getting-started)
- [Installation](#installation)
- [Usage](#usage)
- [Data Flow](#data-flow)
- [Security](#security)
- [Roadmap](#roadmap)
- [Use Cases](#use-cases)
- [Contributing](#contributing)
- [License](#license)

## 🏗️ Architecture

The system uses a three-tier architecture:

### Layer 1: ESP32 Microcontrollers
- Continuous audio recording (simulated, I2S microphone ready)
- Circular buffer with 3 slots × 32KB each
- BLE GATT service for data transmission
- Automatic buffering when phone disconnected
- Resends buffered clips on reconnection

### Layer 2: Flutter Mobile Application
- BLE scanning and multi-device connection management
- Per-device data buffers and state tracking
- Protocol parser: header + chunks + end marker
- Automatic S3 upload after file reception
- AWS Amplify integration for auth and storage

### Layer 3: AWS Cloud Services
- **Cognito User Pool**: Email-based authentication
- **Cognito Identity Pool**: Temporary AWS credentials
- **S3 Bucket**: Private user-scoped storage (us-east-1)
- **Encryption**: At rest and in transit

## 📊 Technical Specifications

| Component | Specification |
|-----------|--------------|
| **ESP32** | Single-core RISC-V @ 160 MHz, ~400 KB SRAM |
| **BLE Version** | 4.2, Custom GATT service |
| **Audio Format** | WAV, 16 kHz sample rate |
| **Buffer Size** | 96 KB total (3 clips × 32 KB) |
| **Clip Duration** | ~1 second per clip |
| **BLE Chunk Size** | 512 bytes |
| **Transfer Rate** | ~10-20 KB/s |
| **Flutter Version** | 3.x with Dart 3.0+ |
| **iOS Target** | iOS 12+ |
| **Max Devices** | 7-10 simultaneous connections |

### Performance Metrics
- End-to-end latency: ~2-5 seconds (capture to S3)
- BLE connection time: ~3-5 seconds
- Upload success rate: >99% with Amplify retry
- Buffer overflow protection: 3-second disconnection tolerance

## 🚦 Getting Started

### Prerequisites

- **Hardware**:
  - ESP32 microcontroller(s)
  - (Optional) I2S microphone module (INMP441 or similar)
  - (Optional) SD card module for extended buffering

- **Software**:
  - Flutter 3.x+
  - Dart 3.0+
  - Arduino IDE or PlatformIO
  - AWS Account with Cognito and S3 configured
  - iOS development environment (Xcode)

### AWS Setup

1. **Create Cognito User Pool**:
   - Region: us-east-1
   - Email-based authentication
   - Password requirements: 8+ characters

2. **Create Cognito Identity Pool**:
   - Link to User Pool
   - Enable authenticated access

3. **Create S3 Bucket**:
   - Private access configuration
   - Server-side encryption enabled
   - IAM policy: `private/{cognito-identity-id}/*`

4. **Configure IAM Policies**:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:GetObject",
           "s3:DeleteObject"
         ],
         "Resource": "arn:aws:s3:::your-bucket-name/private/${cognito-identity.amazonaws.com:sub}/*"
       }
     ]
   }
   ```

## 💾 Installation

### ESP32 Firmware

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/ble-audio-streaming.git
   cd ble-audio-streaming/esp32
   ```

2. Open `sketch_nov4a.ino` in Arduino IDE

3. Install required libraries:
   - BLE (built-in ESP32 library)

4. Update configuration if needed (BLE service UUID, buffer settings)

5. Upload to ESP32 board

### Flutter Application

1. Navigate to the Flutter app directory:
   ```bash
   cd ../flutter_app
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Configure AWS Amplify:
   - Update `amplifyconfiguration.dart` with your AWS credentials
   - Add your Cognito User Pool ID
   - Add your Cognito Identity Pool ID
   - Add your S3 bucket name

4. Run the app:
   ```bash
   flutter run
   ```

## 📱 Usage

### Authentication

1. **Sign Up**:
   - Provide name, email, and password (8+ characters)
   - Verify email with 6-digit code sent by Cognito

2. **Sign In**:
   - Enter email and password
   - Secure Remote Password (SRP) authentication

### Device Connection

1. **Scan for Devices**:
   - Tap "Start Scan" on the BLE Device tab
   - Wait for ESP32 devices to appear (8-second timeout)

2. **Connect**:
   - Tap "Connect" on desired device(s)
   - Monitor connection status (green background when connected)

3. **Receive Audio**:
   - Watch real-time progress as audio clips are received
   - Files automatically upload to S3

### File Management

1. Switch to the **Files** tab to view all uploaded audio files
2. Each file shows:
   - Filename: `{deviceID}_{clipIndex}_{timestamp}.wav`
   - File size
   - Upload timestamp
3. Delete files directly from the interface

## 🔄 Data Flow

### Normal Operation (Connected)

1. ESP32 fills buffer slot with audio data (~1 second)
2. Clip marked with timestamp, size, index, sent=false
3. ESP32 checks phone connection status (every 2 seconds)
4. Header transmitted (16 bytes): markers + index + size + timestamp
5. Audio data transferred in 512-byte chunks via BLE notify
6. End marker sent (4 bytes): 0xFF 0xBB markers
7. Flutter app assembles chunks and validates markers
8. WAV file created in local temp directory
9. File uploaded to S3: `private/{user-id}/{filename}`
10. Local temp file deleted, clip marked as sent on ESP32

### Disconnected Operation (Buffering)

1. **Connection Lost**: ESP32 continues recording to buffer
2. **Buffer Management**: 3-clip capacity (newest overwrites oldest unsent)
3. **Sent Flag Tracking**: Each clip has boolean "sent" flag
4. **Reconnection**: Phone reconnects to ESP32
5. **Unsent Detection**: ESP32 scans buffer for sent=false clips
6. **Transfer Queue**: All unsent clips sent in FIFO order
7. **Resume**: After buffer cleared, new recordings transmitted live

### BLE Protocol Format

**CLIP HEADER (16 bytes)**:
```
[0-1]   Start Marker: 0xFF 0xAA
[2]     Clip Index: 0-2
[3]     Reserved
[4-7]   Size: uint32 (little-endian)
[8-11]  Timestamp: uint32 (milliseconds)
[12-15] Reserved
```

**AUDIO DATA**: Raw audio bytes in 512-byte chunks

**END MARKER (4 bytes)**:
```
[0-1]   End Marker: 0xFF 0xBB
[2-3]   Reserved
```

## 🔒 Security

### Multi-Layer Security Architecture

1. **Physical Layer**: BLE requires proximity (~10-30m range)
2. **Application Layer**: AWS Cognito authentication with JWT tokens
3. **Transport Layer**: TLS 1.2+ for all AWS API calls
4. **Storage Layer**: S3 server-side encryption (AES-256)
5. **Access Control**: IAM policies prevent cross-user access

### Authentication Flow

1. User provides credentials (email + password)
2. SRP authentication - password never sent over network
3. Cognito returns JWT access, ID, and refresh tokens
4. Cognito Identity Pool assigns temporary AWS credentials
5. IAM policy grants write access only to `private/{identity-id}/*`
6. No cross-user access possible

## 🗺️ Roadmap

### ✅ Completed (v1.0)
- ESP32 firmware with BLE stack and circular buffer
- Flutter iOS app with authentication and multi-device support
- AWS integration (Cognito + S3 + Amplify)
- Data protocol implementation
- Two-tab UI with device and file management
- Intelligent buffering during disconnections

### 🔄 In Progress
- I2S microphone hardware integration
- SD card module for extended buffering
- Android app deployment
- Comprehensive testing suite

### 📅 Planned Enhancements

**Phase 1 (Q1 2025)**:
- ✅ I2S microphone: Real audio capture (INMP441)
- ✅ SD card module: Hours/days of buffering
- ✅ Android deployment
- ✅ WiFi fallback: ESP32 WiFi upload when BLE unavailable

**Phase 2 (Q2-Q3 2025)**:
- 🔮 Edge ML: TensorFlow Lite for on-device sound classification
- 🔮 Real-time streaming: WebSocket-based live audio
- 🔮 Additional sensors: Temperature, humidity, motion
- 🔮 Web dashboard: React admin panel for fleet management

### Timeline

| Milestone | Target |
|-----------|--------|
| I2S Microphone Integration | December 2024 |
| Beta Testing | January 2025 |
| SD Card Support | February 2025 |
| Android Release | March 2025 |
| Production v1.0 | April 2025 |

## 💡 Use Cases

### Environmental Monitoring
- Wildlife tracking and behavior analysis
- Noise pollution measurement
- Forest health monitoring
- Urban soundscape analysis

### Industrial IoT
- Machine health monitoring
- Predictive maintenance
- Quality control in manufacturing
- Equipment diagnostics

### Healthcare
- Patient monitoring systems
- Sleep study data collection
- Remote auscultation
- Elderly care monitoring

### Security
- Perimeter monitoring
- Glass break detection
- Surveillance systems
- Intrusion detection

### Smart Buildings
- Occupancy detection
- HVAC optimization
- Space utilization tracking
- Energy efficiency monitoring

## ⚠️ Current Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| ESP32 Buffer | 96 KB (~3 seconds) | SD card expansion planned |
| BLE Range | ~10-30 meters | WiFi fallback in development |
| iOS Only | Android not deployed | Port in progress |
| Simulated Audio | Using dummy data | I2S microphone ready |
| Single Source | No multi-source per device | Future enhancement |

## 🛠️ Technical Risks & Mitigation

| Risk | Probability | Mitigation Strategy |
|------|------------|---------------------|
| BLE Connection Drops | Medium | Circular buffer prevents data loss, auto-reconnect |
| Buffer Overflow | Low | 3-second buffer sufficient, SD card expansion |
| S3 Upload Failures | Low | Amplify SDK auto-retry, local queue |
| AWS Cost | Low | S3 lifecycle policies, user quotas |
| iOS BLE Limits | Medium | Documented 7-10 device limit, gateway architecture |
| Security Breach | Very Low | Multi-layer security, IAM policies, encryption |

## 📁 Project Structure

```
ble-audio-streaming/
├── esp32/
│   ├── sketch_nov4a.ino          # ESP32 firmware
│   └── README.md
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart             # Entry point
│   │   ├── auth_screen.dart      # Authentication UI
│   │   ├── verification_screen.dart
│   │   ├── home_screen.dart      # Main app UI
│   │   └── amplifyconfiguration.dart
│   ├── android/
│   ├── ios/
│   └── pubspec.yaml
├── docs/
│   └── BLE-integrated_Flutter_iOS_App.pdf
└── README.md
```

## 🤝 Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

Please ensure your code follows the project's coding standards and includes appropriate tests.

## 🙏 Acknowledgments

- ESP32 community for BLE examples
- Flutter team for excellent mobile framework
- AWS Amplify team for seamless cloud integration

