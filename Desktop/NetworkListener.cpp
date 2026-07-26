#include "NetworkListener.h"
#include "MainWindow.h"  // for LogManager
#include "NetworkInterfaceDescription.h"
#include "ReceiverRouteClassifier.h"

#include <QHostAddress>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkInterface>
#include <QUuid>
#include <QtEndian>
#include <vector>

NetworkListener::NetworkListener(QObject* parent)
    : QObject(parent)
    , m_lastKeyframeRequest(QDateTime::fromMSecsSinceEpoch(0))
    , m_lastStatsTime(QDateTime::currentDateTime())
{
}

NetworkListener::~NetworkListener() {
    stop();
}

uint16_t NetworkListener::actualTcpPort() const {
    if (m_tcpServer && m_tcpServer->isListening())
        return m_tcpServer->serverPort();
    return kDefaultTcpPort;
}

void NetworkListener::start() {
    if (isListening()) {
        emit statusChanged(QString("Listening on port %1").arg(actualTcpPort()));
        return;
    }

    // Start TCP server
    m_tcpServer = new QTcpServer(this);
    connect(m_tcpServer, &QTcpServer::newConnection, this, &NetworkListener::onNewTcpConnection);

    if (m_tcpServer->listen(QHostAddress::Any, kDefaultTcpPort)) {
        LogManager::instance().log(QString("TCP listening on port %1").arg(m_tcpServer->serverPort()));
        emit statusChanged(QString("Listening on port %1").arg(m_tcpServer->serverPort()));
    } else {
        LogManager::instance().log(QString("TCP port %1 unavailable: %2 — trying system-assigned port")
                                       .arg(kDefaultTcpPort).arg(m_tcpServer->errorString()));
        // Try any available port if default is taken
        if (m_tcpServer->listen(QHostAddress::Any, 0)) {
            LogManager::instance().log(QString("TCP listening on fallback port %1").arg(m_tcpServer->serverPort()));
            emit statusChanged(QString("Listening on port %1 (fallback)").arg(m_tcpServer->serverPort()));
        } else {
            qWarning() << "TCP listen failed:" << m_tcpServer->errorString();
            emit statusChanged("TCP listen failed: " + m_tcpServer->errorString());
        }
    }

    // Start UDP socket
    m_udpSocket = new QUdpSocket(this);
    if (m_udpSocket->bind(QHostAddress::Any, kDefaultUdpPort)) {
        connect(m_udpSocket, &QUdpSocket::readyRead, this, &NetworkListener::onUdpReadyRead);
        qDebug() << "UDP listening on port" << kDefaultUdpPort;
    } else {
        qWarning() << "UDP bind failed:" << m_udpSocket->errorString();
    }

    // Heartbeat timer (every 500ms, matching Swift receiver)
    m_heartbeatTimer = new QTimer(this);
    connect(m_heartbeatTimer, &QTimer::timeout, this, &NetworkListener::onHeartbeatTick);
    m_heartbeatTimer->start(500);
}

void NetworkListener::stop() {
    disconnectAll();

    if (m_heartbeatTimer) {
        m_heartbeatTimer->stop();
        delete m_heartbeatTimer;
        m_heartbeatTimer = nullptr;
    }

    if (m_udpSocket) {
        m_udpSocket->close();
        delete m_udpSocket;
        m_udpSocket = nullptr;
    }

    if (m_tcpServer) {
        m_tcpServer->close();
        delete m_tcpServer;
        m_tcpServer = nullptr;
    }

    {
        QMutexLocker lock(&m_udpMutex);
        m_udpBuffer.clear();
    }
}

bool NetworkListener::isListening() const {
    return m_tcpServer && m_tcpServer->isListening();
}

void NetworkListener::disconnectAll() {
    for (auto* client : m_clients) {
        client->disconnect(); // disconnect signals
        client->abort();
        client->deleteLater();
    }
    m_clients.clear();
    m_tcpBuffers.clear();
    m_connectionFormat.clear();
    m_connectionIds.clear();
    m_socketsByConnectionId.clear();
    m_inboundSessions.clear();
}

void NetworkListener::adoptConnectedRemoteSender(QTcpSocket* socket) {
    if (!socket || socket->state() != QAbstractSocket::ConnectedState) {
        return;
    }
    socket->setParent(this);
    adoptInboundSocket(
        socket,
        "Compatibility TCP connected to "
            + socket->peerAddress().toString()
    );
}

void NetworkListener::adoptInboundSocket(
    QTcpSocket* socket,
    const QString& logDescription
) {
    registerSocket(socket);
    connect(socket, &QTcpSocket::readyRead, this, &NetworkListener::onTcpReadyRead);
    connect(socket, &QTcpSocket::disconnected, this, &NetworkListener::onTcpDisconnected);
    LogManager::instance().log(logDescription + " — waiting for sender identity");
}

void NetworkListener::onNewTcpConnection() {
    while (m_tcpServer->hasPendingConnections()) {
        auto* socket = m_tcpServer->nextPendingConnection();
        socket->setSocketOption(QAbstractSocket::LowDelayOption, 1);
        socket->setSocketOption(QAbstractSocket::KeepAliveOption, 1);

        qDebug() << "New TCP connection from" << socket->peerAddress().toString();
        adoptInboundSocket(
            socket,
            "TCP accepted from " + socket->peerAddress().toString()
        );
    }
}

QString NetworkListener::connectionIdFor(QTcpSocket* socket) const {
    return m_connectionIds.value(socket);
}

QString NetworkListener::connectionModeFor(QTcpSocket* socket) const {
    if (!socket) return "Local Network";

    bool hasLocalIpv4 = false;
    const quint32 localIpv4 = socket->localAddress().toIPv4Address(
        &hasLocalIpv4
    );
    if (!hasLocalIpv4) return "Local Network";

    for (const auto& iface : QNetworkInterface::allInterfaces()) {
        std::vector<std::string> ipv4Addresses;
        bool ownsLocalAddress = false;
        for (const auto& entry : iface.addressEntries()) {
            bool hasInterfaceIpv4 = false;
            const quint32 interfaceIpv4 =
                entry.ip().toIPv4Address(&hasInterfaceIpv4);
            if (!hasInterfaceIpv4) continue;
            ipv4Addresses.push_back(entry.ip().toString().toStdString());
            ownsLocalAddress = ownsLocalAddress
                || interfaceIpv4 == localIpv4;
        }
        if (!ownsLocalAddress) continue;

        switch (classifyReceiverAdvertisedRoute(
            detailedNetworkInterfaceDescription(iface).toStdString(),
            ipv4Addresses,
#ifdef _WIN32
            true
#else
            false
#endif
        )) {
        case ReceiverAdvertisedRoute::wifi:
            return "Wi-Fi";
        case ReceiverAdvertisedRoute::ethernet:
            return "Ethernet";
        case ReceiverAdvertisedRoute::thunderbolt:
            return "Thunderbolt Bridge";
        case ReceiverAdvertisedRoute::excluded:
            return "Local Network";
        }
    }
    return "Local Network";
}

void NetworkListener::registerSocket(QTcpSocket* socket) {
    if (!socket || m_connectionIds.contains(socket)) {
        return;
    }
    const QString connectionId =
        QUuid::createUuid().toString(QUuid::WithoutBraces).toLower();
    const QString peerAddress = socket->peerAddress().toString();

    m_clients.append(socket);
    m_tcpBuffers[socket] = QByteArray();
    m_connectionFormat[socket] = -1;
    m_connectionIds[socket] = connectionId;
    m_socketsByConnectionId[connectionId] = socket;
    m_inboundSessions.open(
        connectionId.toStdString(),
        peerAddress.toStdString(),
        peerAddress.toStdString()
    );
}

void NetworkListener::onTcpReadyRead() {
    auto* socket = qobject_cast<QTcpSocket*>(sender());
    if (!socket) return;

    QByteArray& buffer = m_tcpBuffers[socket];
    buffer.append(socket->readAll());

    // Safety: if buffer grows beyond 32MB, framing is likely desynced — reset
    if (buffer.size() > kMaxBufferSize) {
        qWarning() << "TCP buffer exceeded" << (kMaxBufferSize / (1024*1024))
                    << "MB — likely framing desync, resetting";
        buffer.clear();
        return;
    }

    processTcpBuffer(socket);
}

void NetworkListener::processTcpBuffer(QTcpSocket* socket) {
    QByteArray& buffer = m_tcpBuffers[socket];
    int consumed = 0;

    // Length-prefixed framing: [uint32_be length][body]
    while (buffer.size() - consumed >= 4) {
        uint32_t length = qFromBigEndian<uint32_t>(
            reinterpret_cast<const uchar*>(buffer.constData() + consumed));

        // Sanity check: single frame should never exceed 8MB
        if (length > kMaxPacketSize) {
            qWarning() << "TCP framing error: packet length" << length
                        << "exceeds max" << kMaxPacketSize << "— resetting buffer";
            buffer.clear();
            consumed = 0;
            return;
        }

        int totalNeeded = 4 + static_cast<int>(length);
        if (buffer.size() - consumed < totalNeeded) {
            break; // Wait for more data
        }

        QByteArray body = buffer.mid(consumed + 4, static_cast<int>(length));
        consumed += totalNeeded;

        // Every media connection must start with a typed identity message.
        int& format = m_connectionFormat[socket];
        const uint8_t typeByte =
            body.isEmpty() ? 0 : static_cast<uint8_t>(body[0]);
        if (format < 0) {
            if (typeByte != 0x03 || body.size() <= 1) {
                rejectUnidentifiedConnection(
                    socket,
                    "first protocol message was not sender identity"
                );
                return;
            }
            format = 1;
        }

        if (format == 1 && body.size() > 1) {
            if (typeByte == 0x03) {
                if (!handleIdentity(socket, body.mid(1))) {
                    return;
                }
            } else if (typeByte == 0x01) {
                // The type byte only wraps the existing video payload. That payload
                // is still [8-byte PTS][AVCC NALUs] for both Mac and desktop senders.
                handleVideoData(socket, body.mid(1), true);
            } else if (typeByte == 0x02) {
                handleAudioData(socket, body.mid(1));
            }
        }
    }

    // Remove all consumed bytes at once (avoids repeated O(n) shifts)
    if (consumed > 0) {
        buffer.remove(0, consumed);
    }
}

bool NetworkListener::handleIdentity(
    QTcpSocket* socket,
    const QByteArray& payload
) {
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(payload, &parseError);
    const QJsonObject identity = document.object();
    const QString deviceId = identity.value("deviceId").toString().trimmed();
    const QString deviceName = identity.value("deviceName").toString().trimmed();
    const int protocolVersion = identity.value("protocolVersion").toInt();
    const QString connectionId = connectionIdFor(socket);

    if (parseError.error != QJsonParseError::NoError
        || !document.isObject()
        || protocolVersion != 1
        || deviceId.isEmpty()
        || deviceName.isEmpty()
        || deviceId.size() > 128
        || deviceName.size() > 128
        || connectionId.isEmpty()) {
        rejectUnidentifiedConnection(socket, "invalid sender identity");
        return false;
    }

    const auto existing = m_inboundSessions.sessionForConnection(
        connectionId.toStdString()
    );
    if (existing.has_value()) {
        if (existing->deviceId != deviceId.toStdString()) {
            rejectUnidentifiedConnection(
                socket,
                "sender identity changed on an active connection"
            );
            return false;
        }
        return true;
    }

    const auto result = m_inboundSessions.identify(
        connectionId.toStdString(),
        deviceId.toStdString(),
        deviceName.toStdString()
    );
    if (!result.has_value()) {
        rejectUnidentifiedConnection(socket, "identity could not be registered");
        return false;
    }

    if (result->replacedConnectionId.has_value()) {
        const QString replacedId =
            QString::fromStdString(*result->replacedConnectionId);
        if (auto* replacedSocket = m_socketsByConnectionId.value(replacedId)) {
            LogManager::instance().log(
                QString("Receiver: %1 moved to a new connection; replacing %2")
                    .arg(deviceName, replacedId)
            );
            replacedSocket->abort();
        }
    }

    const QString peerAddress = socket->peerAddress().toString();
    const quint16 peerPort = socket->peerPort();
    const QString connectionMode = connectionModeFor(socket);
    LogManager::instance().log(
        QString("Receiver: Identified %1 (%2) from %3:%4 via %5 "
                "[connection %6]")
            .arg(deviceName)
            .arg(deviceId)
            .arg(peerAddress)
            .arg(peerPort)
            .arg(connectionMode)
            .arg(connectionId)
    );
    emit connectionEstablished(
        deviceId,
        deviceName,
        connectionId,
        peerAddress,
        peerPort,
        connectionMode
    );
    emit statusChanged(
        QString("Connected to %1 sender(s)")
            .arg(static_cast<qulonglong>(
                m_inboundSessions.activeSessionCount()
            ))
    );
    return true;
}

void NetworkListener::rejectUnidentifiedConnection(
    QTcpSocket* socket,
    const QString& reason
) {
    LogManager::instance().log(
        QString("Receiver: Ignoring unidentified TCP connection from %1 — %2")
            .arg(
                socket
                    ? socket->peerAddress().toString()
                    : QStringLiteral("unknown")
            )
            .arg(reason)
    );
    if (socket) {
        socket->abort();
    }
}

void NetworkListener::handleVideoData(
    QTcpSocket* socket,
    const QByteArray& data,
    bool hasPtsPrefix
) {
    const auto binding = m_inboundSessions.sessionForConnection(
        connectionIdFor(socket).toStdString()
    );
    if (!binding.has_value()) {
        rejectUnidentifiedConnection(socket, "video arrived before sender identity");
        return;
    }

    static int frameCount = 0;
    frameCount++;
    if (frameCount <= 5 || frameCount % 300 == 0) {
        // Log first few bytes for debugging framing issues
        QString hexPreview;
        int previewLen = qMin(data.size(), 16);
        for (int i = 0; i < previewLen; i++) {
            hexPreview += QString("%1 ").arg(static_cast<uint8_t>(data[i]), 2, 16, QChar('0'));
        }
        LogManager::instance().log(QString("Video: frame %1, %2 bytes, pts=%3 [%4]")
                                   .arg(frameCount).arg(data.size()).arg(hasPtsPrefix).arg(hexPreview.trimmed()));
    }
    emit videoDataReceived(
        QString::fromStdString(binding->deviceId),
        data,
        hasPtsPrefix
    );
}

void NetworkListener::handleAudioData(
    QTcpSocket* socket,
    const QByteArray& data
) {
    const auto binding = m_inboundSessions.sessionForConnection(
        connectionIdFor(socket).toStdString()
    );
    if (!binding.has_value()) {
        rejectUnidentifiedConnection(socket, "audio arrived before sender identity");
        return;
    }

    static int audioCount = 0;
    audioCount++;
    if (audioCount <= 3 || audioCount % 200 == 0) {
        qDebug() << "NetworkListener: Received audio data" << data.size() << "bytes (packet" << audioCount << ")";
    }
    emit audioDataReceived(
        QString::fromStdString(binding->deviceId),
        data
    );
}

void NetworkListener::onTcpDisconnected() {
    auto* socket = qobject_cast<QTcpSocket*>(sender());
    if (!socket) return;

    qDebug() << "TCP client disconnected:" << socket->peerAddress().toString();
    const QString connectionId = connectionIdFor(socket);
    const InboundCloseResult closed =
        m_inboundSessions.close(connectionId.toStdString());
    m_clients.removeAll(socket);
    m_tcpBuffers.remove(socket);
    m_connectionFormat.remove(socket);
    m_connectionIds.remove(socket);
    m_socketsByConnectionId.remove(connectionId);
    socket->deleteLater();

    if (!closed.wasActive) {
        LogManager::instance().log(
            "Receiver: Unidentified/probe connection closed without affecting a window"
        );
        return;
    }

    emit connectionLost(QString::fromStdString(closed.deviceId));
    if (m_inboundSessions.activeSessionCount() == 0) {
        emit statusChanged("Waiting for connection...");
    } else {
        emit statusChanged(
            QString("Connected to %1 sender(s)")
                .arg(static_cast<qulonglong>(
                    m_inboundSessions.activeSessionCount()
                ))
        );
    }
}

void NetworkListener::onUdpReadyRead() {
    while (m_udpSocket->hasPendingDatagrams()) {
        QByteArray datagram;
        datagram.resize(static_cast<int>(m_udpSocket->pendingDatagramSize()));
        m_udpSocket->readDatagram(datagram.data(), datagram.size());

        if (!datagram.isEmpty()) {
            handleUdpPacket(datagram);
        }
    }
}

void NetworkListener::handleUdpPacket(const QByteArray& data) {
    if (data.size() <= 8) return;

    const uchar* raw = reinterpret_cast<const uchar*>(data.constData());
    uint32_t frameId = qFromBigEndian<uint32_t>(raw);
    uint16_t chunkId = qFromBigEndian<uint16_t>(raw + 4);
    uint16_t totalChunks = qFromBigEndian<uint16_t>(raw + 6);

    QByteArray payload = data.mid(8);

    QMutexLocker lock(&m_udpMutex);

    if (m_lastDecodedFrameId == 0) {
        m_lastDecodedFrameId = frameId - 1;
    }

    m_udpPacketsReceived++;

    // Stats logging every 3 seconds
    auto now = QDateTime::currentDateTime();
    if (m_lastStatsTime.msecsTo(now) > 3000) {
        qDebug() << "UDP Stats (3s): Pkts:" << m_udpPacketsReceived
                 << "Frames:" << m_udpFramesReassembled;
        m_udpPacketsReceived = 0;
        m_udpFramesReassembled = 0;
        m_lastStatsTime = now;
    }

    if (!m_udpBuffer.contains(frameId)) {
        UdpFrameEntry entry;
        entry.totalChunks = totalChunks;
        entry.timestamp = now;
        m_udpBuffer[frameId] = entry;
    }

    m_udpBuffer[frameId].chunks[chunkId] = payload;

    if (m_udpBuffer[frameId].chunks.size() == m_udpBuffer[frameId].totalChunks) {
        m_udpFramesReassembled++;

        // Gap detection — request IDR if frames were skipped
        int diff = static_cast<int>(frameId) - static_cast<int>(m_lastDecodedFrameId);
        if (diff > 1 && diff < 1000) {
            if (m_lastKeyframeRequest.msecsTo(now) > 2000) {
                qDebug() << "Frame gap detected" << m_lastDecodedFrameId << "->" << frameId << "requesting IDR";
                const InputEvent request(
                    InputEventType::Command,
                    0,
                    0,
                    kIDRRequestKeyCode
                );
                for (auto* client : m_clients) {
                    if (m_inboundSessions.sessionForConnection(
                            connectionIdFor(client).toStdString()
                        ).has_value()) {
                        writeInputEvent(client, request);
                    }
                }
                m_lastKeyframeRequest = now;
            }
        }
        m_lastDecodedFrameId = frameId;

        m_udpBuffer.remove(frameId);

        // Unlock before decode (decode may be slow)
        lock.unlock();
        static bool loggedMissingUdpIdentity = false;
        if (!loggedMissingUdpIdentity) {
            LogManager::instance().log(
                "Receiver: UDP media ignored because it has no sender identity"
            );
            loggedMissingUdpIdentity = true;
        }
        return;
    }

    // Periodic cleanup of stale incomplete frames
    if (m_udpPacketsReceived % 100 == 0) {
        QList<uint32_t> staleKeys;
        for (auto it = m_udpBuffer.begin(); it != m_udpBuffer.end(); ++it) {
            if (it->timestamp.msecsTo(now) > 1000) {
                staleKeys.append(it.key());
            }
        }
        for (uint32_t key : staleKeys) {
            m_udpBuffer.remove(key);
        }
    }
}

void NetworkListener::onHeartbeatTick() {
    InputEvent heartbeat(InputEventType::Command, 0, 0, kHeartbeatKeyCode);
    QByteArray packet = heartbeat.toPacket();

    for (auto* client : m_clients) {
        if (m_inboundSessions.sessionForConnection(
                connectionIdFor(client).toStdString()
            ).has_value()) {
            client->write(packet);
        }
    }
}

void NetworkListener::writeInputEvent(
    QTcpSocket* socket,
    const InputEvent& event
) {
    if (!socket) {
        return;
    }
    bool isCritical = (event.type == InputEventType::LeftMouseDown ||
                       event.type == InputEventType::LeftMouseUp ||
                       event.type == InputEventType::RightMouseDown ||
                       event.type == InputEventType::RightMouseUp ||
                       event.type == InputEventType::KeyDown ||
                       event.type == InputEventType::KeyUp ||
                       event.type == InputEventType::Command);

    int repeatCount = isCritical ? 3 : 1;
    QByteArray packet = event.toPacket();

    for (int i = 0; i < repeatCount; i++) {
        socket->write(packet);
    }
}

void NetworkListener::sendInputEvent(
    const QString& deviceId,
    const InputEvent& event
) {
    const auto binding =
        m_inboundSessions.sessionForDevice(deviceId.toStdString());
    if (!binding.has_value()) {
        return;
    }
    if (auto* socket = m_socketsByConnectionId.value(
            QString::fromStdString(binding->connectionId)
        )) {
        writeInputEvent(socket, event);
    }
}
