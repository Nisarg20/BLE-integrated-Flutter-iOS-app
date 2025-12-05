#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

// Audio buffer settings
#define MAX_CLIPS 3              // Store last 3 clips
#define CLIP_SIZE 16000          // ~15.57KB per clip
#define CHUNK_SIZE 512           // BLE chunk size

struct AudioClip {
  uint8_t data[CLIP_SIZE];
  uint16_t actualSize;
  uint32_t timestamp;
  bool sent;
};

AudioClip audioBuffer[MAX_CLIPS];
int currentClipIndex = 0;
int recordingPosition = 0;
unsigned long lastRecordTime = 0;

BLEServer *pServer = NULL;
BLECharacteristic *pCharacteristic = NULL;
bool deviceConnected = false;
bool transferInProgress = false;

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println("📱 Device connected - Starting transfer");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      transferInProgress = false;
      Serial.println("📱 Device disconnected");
      delay(500);
      BLEDevice::startAdvertising();
      Serial.println("📡 Advertising restarted");
    }
};

void setup() {
  Serial.begin(115200);
  Serial.println("🎤 ESP32 Audio Recorder Starting...");
  
  // Initialize audio buffer
  for (int i = 0; i < MAX_CLIPS; i++) {
    audioBuffer[i].actualSize = 0;
    audioBuffer[i].timestamp = 0;
    audioBuffer[i].sent = true; // Mark as sent initially
  }
  
  // Setup BLE
  BLEDevice::init("ESP32_Audio_01"); // Change for each device: _01, _02, etc.
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  
  BLEService *pService = pServer->createService(SERVICE_UUID);
  
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ | 
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  
  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();
  
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  
  Serial.println("✅ BLE ready - Device name: ESP32_Audio_01");
  Serial.println("🎙️ Starting continuous recording simulation...");
}

void simulateAudioRecording() {
  // This simulates recording - replace with actual I2S audio capture later
  
  // Record one sample every 25ms (simulating 16kHz sample rate)
  if (millis() - lastRecordTime >= 2) {
    lastRecordTime = millis();
    
    // Generate fake audio data (replace with real mic data)
    audioBuffer[currentClipIndex].data[recordingPosition++] = random(0, 255);
    
    // Check if we've filled 1 second of audio (~40KB)
    if (recordingPosition >= CLIP_SIZE) {
      finishCurrentClip();
    }
  }
}

void finishCurrentClip() {
  audioBuffer[currentClipIndex].actualSize = recordingPosition;
  audioBuffer[currentClipIndex].timestamp = millis();
  audioBuffer[currentClipIndex].sent = false;
  
  Serial.print("✅ Clip #");
  Serial.print(currentClipIndex);
  Serial.println(" recorded");
  // Serial.print(recordingPosition);
  // Serial.println(" bytes)");
  
  // Move to next clip slot (circular buffer)
  currentClipIndex = (currentClipIndex + 1) % MAX_CLIPS;
  recordingPosition = 0;
  
  // Mark this slot as ready for new recording
  audioBuffer[currentClipIndex].sent = true;
}

void transferBufferedClips() {
  if (!deviceConnected || transferInProgress) return;
  
  // Find unsent clips
  int unsentCount = 0;
  for (int i = 0; i < MAX_CLIPS; i++) {
    if (!audioBuffer[i].sent && audioBuffer[i].actualSize > 0) {
      unsentCount++;
    }
  }
  
  if (unsentCount == 0) {
    Serial.println("✅ All clips sent");
    return;
  }
  
  Serial.print("📤 Found ");
  Serial.print(unsentCount);
  Serial.println(" unsent clips. Starting transfer...");
  
  transferInProgress = true;
  
  // Transfer each unsent clip
  for (int i = 0; i < MAX_CLIPS && deviceConnected; i++) {
    if (!audioBuffer[i].sent && audioBuffer[i].actualSize > 0) {
      sendClip(i);
    }
  }
  
  transferInProgress = false;
  Serial.println("✅ Transfer complete");
}

void sendClip(int clipIndex) {
  Serial.print("📤 Sending clip #");
  Serial.print(clipIndex);
  Serial.print(" (");
  Serial.print(audioBuffer[clipIndex].actualSize);
  Serial.println(" bytes)");
  
  // Send clip header: [START_MARKER][CLIP_INDEX][SIZE][TIMESTAMP]
  uint8_t header[16];
  header[0] = 0xFF; // Start marker
  header[1] = 0xAA; // Start marker
  header[2] = clipIndex;
  header[3] = 0x00; // Reserved
  
  // Size (4 bytes)
  memcpy(&header[4], &audioBuffer[clipIndex].actualSize, 4);
  
  // Timestamp (4 bytes)
  memcpy(&header[8], &audioBuffer[clipIndex].timestamp, 4);
  
  // Send header
  pCharacteristic->setValue(header, 16);
  pCharacteristic->notify();
  delay(50);
  
  // Send audio data in chunks
  int offset = 0;
  int totalSize = audioBuffer[clipIndex].actualSize;
  
  while (offset < totalSize && deviceConnected) {
    int remainingBytes = totalSize - offset;
    int bytesToSend = (remainingBytes < CHUNK_SIZE) ? remainingBytes : CHUNK_SIZE;
    
    pCharacteristic->setValue(&audioBuffer[clipIndex].data[offset], bytesToSend);
    pCharacteristic->notify();
    
    offset += bytesToSend;
    delay(50); // Prevent buffer overflow
  }
  
  // Send end marker
  uint8_t endMarker[4] = {0xFF, 0xBB, 0x00, 0x00};
  pCharacteristic->setValue(endMarker, 4);
  pCharacteristic->notify();
  delay(50);
  
  // Mark as sent
  audioBuffer[clipIndex].sent = true;
  
  Serial.print("✅ Clip #");
  Serial.print(clipIndex);
  Serial.println(" sent successfully");
}

void loop() {
  // Always record (even when not connected)
  simulateAudioRecording();
  
  // Transfer buffered clips when connected
  if (deviceConnected && !transferInProgress) {
    static unsigned long lastTransferCheck = 0;
    
    // Check for unsent clips every 2 seconds
    if (millis() - lastTransferCheck >= 2000) {
      lastTransferCheck = millis();
      transferBufferedClips();
    }
  }
  
  delay(1); // Small delay to prevent watchdog issues
}