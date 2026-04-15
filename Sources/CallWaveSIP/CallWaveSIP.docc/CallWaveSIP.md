# ``CallWaveSIP``

A modular, production-ready iOS SIP/VoIP SDK built on top of PJSIP.

## Overview

CallWaveSIP provides a clean, high-level Swift API for SIP communications on iOS,
hiding all PJSIP/C complexity behind type-safe Swift interfaces.

## Topics

### Getting Started

- ``CallWaveSIP``
- ``SIPConfiguration``
- ``SIPAccountConfiguration``

### Account Management

- ``SIPAccountManagerProtocol``
- ``SIPRegistrationState``

### Call Management

- ``SIPCallManagerProtocol``
- ``SIPCall``
- ``SIPCallState``

### Media

- ``SIPMediaManagerProtocol``
- ``SIPAudioRoute``

### CallKit Integration

- ``CallKitAdapterProtocol``
- ``CallKitConfiguration``
- ``VoIPPushHandlerProtocol``

### Events & Errors

- ``SIPEvent``
- ``SIPError``
- ``CallWaveSIPDelegate``
