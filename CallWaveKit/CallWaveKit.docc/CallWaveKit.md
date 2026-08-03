# ``CallWaveKit``

Build incoming SIP audio calls for an iOS intercom app.

CallWaveKit coordinates PJSIP, CallKit, PushKit and AVAudioSession. It supports
library-owned integration and host-owned integration for apps such as Majordom
that already manage CallKit and PushKit.

## Topics

### Runtime and account

- ``CallWaveClient``
- ``CallWaveEngineConfiguration``
- ``CallWaveConfiguration``
- ``CallWaveTURNConfiguration``

### Calls and events

- ``CallWaveEvent``
- ``CallWaveIncomingCallDescriptor``
- ``CallWaveCallStatistics``

### Audio and diagnostics

- ``CallWaveAudioRoute``
- ``CallWaveDiagnosticsSnapshot``
